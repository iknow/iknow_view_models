# frozen_string_literal: true

require 'view_model/after_transaction_runner'

# Concern providing caching configuration and lookup on viewmodels.
module ViewModel::ActiveRecord::Cache::CacheableView
  extend ActiveSupport::Concern

  # Callback handler to participate in ActiveRecord::ConnectionAdapters::
  # Transaction callbacks: invalidates a given cache member after the current
  # transaction commits.
  CacheClearer = Struct.new(:cache, :id) do
    include ViewModel::AfterTransactionRunner

    def after_transaction
      cache.delete(id)
    end

    def connection
      cache.viewmodel_class.model_class.connection
    end
  end

  class_methods do
    def create_viewmodel_cache!(**opts)
      @viewmodel_cache = ViewModel::ActiveRecord::Cache.new(self, **opts)
    end

    def viewmodel_cache
      @viewmodel_cache
    end

    def serialize_from_cache(views, serialize_context:)
      plural = views.is_a?(Array)
      views = Array.wrap(views)
      json_views, json_refs = viewmodel_cache.fetch_by_viewmodel(views, serialize_context: serialize_context)
      json_views = json_views.first unless plural
      return json_views, json_refs
    end
  end

  # Clear the cache if the view or its owned children were changed during
  # deserialization
  def after_deserialize(deserialize_context:, changes:)
    super if defined?(super)

    if !changes.new? && changes.changed_tree?
      CacheClearer.new(self.class.viewmodel_cache, id).add_to_transaction
    end
  end
end
