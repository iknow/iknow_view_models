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

  included do
    @viewmodel_cache = ViewModel::ActiveRecord::Cache.new(self)
  end

  class_methods do
    def viewmodel_cache
      @viewmodel_cache
    end

    def specialize_cache!(name, prune: nil, include: nil)
      viewmodel_cache.add_specialization(name, prune: prune, include: include)
    end

    def serialize_from_cache(views, serialize_context:)
      plural = views.is_a?(Array)
      views = Array.wrap(views)
      json_views, json_refs = viewmodel_cache.fetch_by_viewmodel(views, serialize_context: serialize_context)
      json_views = json_views.first unless plural
      return json_views, json_refs
    end
  end

  # Conservatively clear the cache whenever the view is considered for edit.
  # This ensures that the cache is also cleared when owned children are
  # edited but the root is untouched.
  def before_deserialize(*)
    super
    CacheClearer.new(self.class.viewmodel_cache, id).add_to_transaction
  end

  def destroy!(*)
    super
    CacheClearer.new(self.class.viewmodel_cache, id).add_to_transaction
  end
end
