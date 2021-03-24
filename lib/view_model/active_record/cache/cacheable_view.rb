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

    # It's important that we clear the cache before committing, because we rely
    # on database locking to prevent cache race conditions. We require
    # reading/refreshing the cache to obtain a FOR SHARE lock, which means that
    # a reader must wait for a concurrent writer to commit before continuing to
    # the cache. If the writer cleared the cache after commit, the reader could
    # obtain old data before the clear, and then save the old data after it.
    def before_commit
      cache.delete(id)
    end

    def after_rollback
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
  end

  # Clear the cache if the view or its nested children were changed during
  # deserialization
  def after_deserialize(deserialize_context:, changes:)
    super if defined?(super)

    if !changes.new? && changes.changed_nested_tree?
      CacheClearer.new(self.class.viewmodel_cache, id).add_to_transaction
    end
  end
end
