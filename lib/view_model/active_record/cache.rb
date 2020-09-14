# frozen_string_literal: true

require 'iknow_cache'

# Cache for ViewModels that wrap ActiveRecord models.
class ViewModel::ActiveRecord::Cache
  require 'view_model/active_record/cache/cacheable_view'
  require 'view_model/migrator'

  class UncacheableViewModelError < RuntimeError; end

  attr_reader :viewmodel_class

  # If cache_group: is specified, it must be a group of a single key: `:id`
  def initialize(viewmodel_class, cache_group: nil)
    @viewmodel_class = viewmodel_class

    @cache_group = cache_group || create_default_cache_group
    @migrated_cache_group = @cache_group.register_child_group(:migrated, :version)

    # /viewname/:id/viewname-currentversion
    @cache = @cache_group.register_cache(cache_name)

    # /viewname/:id/migrated/:oldversion/viewname-currentversion
    @migrated_cache = @migrated_cache_group.register_cache(cache_name)
  end

  def delete(*ids)
    ids.each do |id|
      @cache_group.delete_all(@cache.key.new(id))
    end
  end

  def clear
    @cache_group.invalidate_cache_group
  end

  def fetch_by_viewmodel(viewmodels, migration_versions: {}, locked: false, serialize_context: @viewmodel_class.new_serialize_context)
    ids = viewmodels.map(&:id)
    fetch(ids, initial_viewmodels: viewmodels, migration_versions: migration_versions, locked: locked, serialize_context: serialize_context)
  end

  def fetch(ids, initial_viewmodels: nil, migration_versions: {}, locked: false, serialize_context: @viewmodel_class.new_serialize_context)
    data_serializations = Array.new(ids.size)
    worker = CacheWorker.new(migration_versions: migration_versions, serialize_context: serialize_context)

    # If initial root viewmodels were provided, visit them to ensure that they
    # are visible. Other than this, no traversal callbacks are performed, as a
    # view may be resolved from the cache without ever loading its viewmodel.
    # Note that if unlocked, these views will be reloaded as part of obtaining a
    # share lock. If the visibility of this viewmodel can change due to edits,
    # it is necessary to obtain a lock before calling `fetch`.
    initial_viewmodels&.each do |v|
      serialize_context.run_callback(ViewModel::Callbacks::Hook::BeforeVisit, v)
      serialize_context.run_callback(ViewModel::Callbacks::Hook::AfterVisit, v)
    end

    # Collect input array positions for each id, allowing duplicates
    positions = ids.each_with_index.with_object({}) do |(id, i), h|
      (h[id] ||= []) << i
    end

    # Fetch duplicates only once
    ids = positions.keys

    # Load existing serializations from the cache
    cached_serializations = worker.load_from_cache(self, ids)
    cached_serializations.each do |id, data|
      positions[id].each do |idx|
        data_serializations[idx] = data
      end
    end

    # Resolve and serialize missing views
    missing_ids = ids.to_set.subtract(cached_serializations.keys)

    # If initial viewmodels have been locked, we can serialize them for cache
    #  misses.
    available_viewmodels =
      if locked
        initial_viewmodels&.each_with_object({}) do |vm, h|
          h[vm.id] = vm if missing_ids.include?(vm.id)
        end
      end

    @viewmodel_class.transaction do
      # Load remaining views and serialize
      viewmodels = worker.find_and_preload_viewmodels(@viewmodel_class, missing_ids.to_a,
                                                      available_viewmodels: available_viewmodels)

      loaded_serializations = worker.serialize_and_cache(viewmodels)
      loaded_serializations.each do |id, data|
        positions[id].each do |idx|
          data_serializations[idx] = data
        end
      end

      # Resolve references
      worker.resolve_references!

      return data_serializations, worker.resolved_references
    end
  end

  class CacheWorker
    SENTINEL = Object.new
    WorklistEntry = Struct.new(:ref_name, :viewmodel)

    attr_reader :migration_versions, :serialize_context, :resolved_references

    def initialize(migration_versions:, serialize_context:)
      @worklist                = {}
      @resolved_references     = {}
      @migration_versions      = migration_versions
      @migrated_cache_versions = {}
      @serialize_context       = serialize_context
    end

    def resolve_references!
      @serialize_context = serialize_context.for_references

      while @worklist.present?
        type_name, required_entries = @worklist.shift
        viewmodel_class = ViewModel::Registry.for_view_name(type_name)

        required_entries.each do |_id, entry|
          @resolved_references[entry.ref_name] = SENTINEL
        end

        if viewmodel_class < CacheableView
          cached_serializations = load_from_cache(viewmodel_class.viewmodel_cache, required_entries.keys)
          cached_serializations.each do |id, data|
            ref_name = required_entries.delete(id).ref_name
            @resolved_references[ref_name] = data
          end
        end

        # Load remaining entries from database
        available_viewmodels = required_entries.each_with_object({}) do |(id, entry), h|
          h[id] = entry.viewmodel if entry.viewmodel
        end

        viewmodels = find_and_preload_viewmodels(viewmodel_class, required_entries.keys,
                                                 available_viewmodels: available_viewmodels)

        loaded_serializations = serialize_and_cache(viewmodels)
        loaded_serializations.each do |id, data|
          ref_name = required_entries[id].ref_name
          @resolved_references[ref_name] = data
        end
      end
    end

    def migrated_cache_version(viewmodel_cache)
      @migrated_cache_versions[viewmodel_cache] ||= viewmodel_cache.migrated_cache_version(migration_versions)
    end

    # Loads the specified entities from the cache and returns a hash of
    # {id=>serialized_view}. Any references encountered are added to the
    # worklist.
    def load_from_cache(viewmodel_cache, ids)
      cached_serializations = viewmodel_cache.load(ids, migrated_cache_version(viewmodel_cache), serialize_context: serialize_context)

      cached_serializations.each_with_object({}) do |(id, cached_serialization), result|
        add_refs_to_worklist(cached_serialization[:ref_cache])
        result[id] = cached_serialization[:data]
      end
    end

    # Serializes the specified preloaded viewmodels and returns a hash of
    # {id=>serialized_view}. If the viewmodel type is cacheable, it will be
    # added to the cache. Any references encountered during serialization are
    # added to the worklist.
    def serialize_and_cache(viewmodels)
      viewmodels.each_with_object({}) do |viewmodel, result|
        builder = Jbuilder.new do |json|
          ViewModel.serialize(viewmodel, json, serialize_context: serialize_context)
        end

        referenced_viewmodels = serialize_context.extract_referenced_views!

        if migration_versions.present?
          migrator = ViewModel::DownMigrator.new(migration_versions)

          # This migration isn't given the chance to inspect/alter the contents
          # of referenced views, only their presence: it's strictly less
          # powerful than migrations on a fully serialized tree, as the only
          # possible action on a referenced child is to delete it. The effect of
          # this is that for sufficiently complex migrations where a parent view
          # must introduce children or alter the contents of its referenced
          # children, we may have to avoid caching while the migration is in
          # use.
          dummy_references = referenced_viewmodels.transform_values do |ref_vm|
            {
              ViewModel::TYPE_ATTRIBUTE    => ref_vm.class.view_name,
              ViewModel::VERSION_ATTRIBUTE => ref_vm.class.schema_version,
              ViewModel::ID_ATTRIBUTE      => ref_vm.id,
            }.freeze
          end

          migrator.migrate!(builder.attributes!, references: dummy_references)

          # Removed dummy references can be removed from referenced_viewmodels.
          referenced_viewmodels.keep_if { |k, _| dummy_references.has_key?(k) }

          # Introduced dummy references cannot be handled.
          if dummy_references.keys != referenced_viewmodels.keys
            version = migration_versions[viewmodel.class]
            raise ViewModel::Error.new(
                    status: 500,
                    detail: "Down-migration for cacheable view #{viewmodel.class} to v#{version} must not introduce new shared references")
          end
        end

        data_serialization = builder.target!

        add_viewmodels_to_worklist(referenced_viewmodels)

        if viewmodel.class < CacheableView
          cacheable_references = referenced_viewmodels.transform_values { |vm| cacheable_reference(vm) }
          target_cache = viewmodel.class.viewmodel_cache
          target_cache.store(viewmodel.id, migrated_cache_version(target_cache), data_serialization, cacheable_references,
                             serialize_context: serialize_context)
        end

        result[viewmodel.id] = data_serialization
      end
    end

    # Resolves viewmodels for the provided ids from the database or
    # available_viewmodels and shallowly preloads them.
    def find_and_preload_viewmodels(viewmodel_class, ids, available_viewmodels: nil)
      viewmodels = []

      if available_viewmodels.present?
        ids = ids.reject do |id|
          if (vm = available_viewmodels[id])
            viewmodels << vm
          end
        end
      end

      if ids.present?
        found = viewmodel_class.find(ids,
                                     eager_include: false,
                                     lock: "FOR SHARE",
                                     serialize_context: serialize_context)
        viewmodels.concat(found)
      end

      ViewModel.preload_for_serialization(viewmodels,
                                          include_referenced: false,
                                          lock: "FOR SHARE",
                                          serialize_context: serialize_context)

      viewmodels
    end

    # Store VM references in the cache as viewmodel name + id pairs.
    def cacheable_reference(viewmodel)
      [viewmodel.class.view_name, viewmodel.id]
    end

    def add_refs_to_worklist(cacheable_references)
      cacheable_references.each do |ref_name, (type, id)|
        next if resolved_references.has_key?(ref_name)
        (@worklist[type] ||= {})[id] = WorklistEntry.new(ref_name, nil)
      end
    end

    def add_viewmodels_to_worklist(referenced_viewmodels)
      referenced_viewmodels.each do |ref_name, viewmodel|
        next if resolved_references.has_key?(ref_name)
        (@worklist[viewmodel.class.view_name] ||= {})[viewmodel.id] = WorklistEntry.new(ref_name, viewmodel)
      end
    end
  end

  def cache_for(migration_version)
    if migration_version
      @migrated_cache
    else
      @cache
    end
  end

  def key_for(id, migration_version)
    if migration_version
      @migrated_cache.key.new(id, migration_version)
    else
      @cache.key.new(id)
    end
  end

  def id_for(key)
    key[:id]
  end

  # Save the provided serialization and reference data in the cache
  def store(id, migration_version, data_serialization, ref_cache, serialize_context:)
    key = key_for(id, migration_version)
    cache_for(migration_version).write(key, { data: data_serialization, ref_cache: ref_cache })
  end

  def load(ids, migration_version, serialize_context:)
    keys = ids.map { |id| key_for(id, migration_version) }
    results = cache_for(migration_version).read_multi(keys)
    results.transform_keys! { |key| id_for(key) }
  end

  def cache_version
    @cache_version ||=
      begin
        versions = @viewmodel_class.deep_schema_version(include_referenced: false)
        ViewModel.schema_hash(versions)
      end
  end

  def migrated_cache_version(migration_versions)
    versions = ViewModel::Migrator.migrated_deep_schema_version(viewmodel_class, migration_versions, include_referenced: false)
    version_hash = ViewModel.schema_hash(versions)

    if version_hash == cache_version
      # no migrations affect this view
      nil
    else
      version_hash
    end
  end

  private

  def create_default_cache_group
    IknowCache.register_group(@viewmodel_class.name, :id)
  end

  # Statically version the cache name based on the (current) deep schema
  # versions of the constituent viewmodels, so that viewmodel changes force
  # invalidation.
  def cache_name
    "vmcache_#{cache_version}"
  end
end
