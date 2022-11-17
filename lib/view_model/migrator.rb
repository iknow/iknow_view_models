# frozen_string_literal: true

class ViewModel
  class Migrator
    EXCLUDE_FROM_MIGRATION = '_exclude_from_migration'

    class << self
      def migrated_deep_schema_version(viewmodel_class, required_versions, include_referenced: true)
        deep_schema_version = viewmodel_class.deep_schema_version(include_referenced: include_referenced)

        if required_versions.present?
          deep_schema_version = deep_schema_version.dup

          required_versions.each do |required_vm_class, required_version|
            name = required_vm_class.view_name
            if deep_schema_version.has_key?(name)
              deep_schema_version[name] = required_version
            end
          end
        end

        deep_schema_version
      end
    end

    def initialize(required_versions)
      @paths = required_versions.each_with_object({}) do |(viewmodel_class, required_version), h|
        if required_version != viewmodel_class.schema_version
          path = viewmodel_class.migration_path(from: required_version, to: viewmodel_class.schema_version)
          h[viewmodel_class.view_name] = path
        end
      end

      @versions = required_versions.each_with_object({}) do |(viewmodel_class, required_version), h|
        h[viewmodel_class.view_name] = [required_version, viewmodel_class.schema_version]
      end
    end

    def migrate!(serialization)
      references = (serialization['references'] ||= {})

      # First visit everything except references; there's no issue with adding
      # new references during this.
      migrate_tree!(serialization.except('references'), references: references)

      # While visiting references itself, we need to take care that we can
      # concurrently modify them (e.g. by adding new referenced views).
      # Moreover, such added references must themselves be visited, as they'll
      # be synthesized at the current version and so may need to be migrated
      # down to the client's requested version.
      visited_refs = []
      loop do
        unvisited_refs = references.keys - visited_refs
        break if unvisited_refs.empty?

        unvisited_refs.each do |ref|
          migrate_tree!(references[ref], references: references)
        end

        visited_refs.concat(unvisited_refs)
      end

      GarbageCollection.garbage_collect_references!(serialization)

      if references.empty?
        serialization.delete('references')
      end
    end

    private

    def migrate_tree!(node, references:)
      case node
      when Hash
        if (type = node[ViewModel::TYPE_ATTRIBUTE])
          version = node[ViewModel::VERSION_ATTRIBUTE]

          # We allow subtrees to be excluded from migration. This is used
          # internally to permit stub references that are not a full
          # serialization of the referenced type: see ViewModel::Cache.
          return if node[EXCLUDE_FROM_MIGRATION]

          if migrate_viewmodel!(type, version, node, references)
            node[ViewModel::MIGRATED_ATTRIBUTE] = true
          end
        end

        node.each_value do |child|
          migrate_tree!(child, references: references)
        end
      when Array
        node.each { |child| migrate_tree!(child, references: references) }
      end
    end

    def migrate_viewmodel!(_view_name, _version, _view_hash, _references)
      raise RuntimeError.new('abstract method')
    end
  end

  class UpMigrator < Migrator
    private

    def migrate_tree!(node, references:)
      if node.is_a?(Hash) && node[ViewModel::TYPE_ATTRIBUTE] == ViewModel::ActiveRecord::FUNCTIONAL_UPDATE_TYPE
        migrate_functional_update!(node, references: references)
      else
        super
      end
    end

    NESTED_FUPDATE_TYPES = ['append', 'update'].freeze

    # The functional update structure uses `_type` internally with a
    # context-dependent meaning. Retrospectively this was a poor choice, but we
    # need to account for it here.
    def migrate_functional_update!(node, references:)
      actions = node[ViewModel::ActiveRecord::ACTIONS_ATTRIBUTE]
      actions&.each do |action|
        action_type = action[ViewModel::TYPE_ATTRIBUTE]
        next unless NESTED_FUPDATE_TYPES.include?(action_type)

        values = action[ViewModel::ActiveRecord::VALUES_ATTRIBUTE]
        values&.each do |value|
          migrate_tree!(value, references: references)
        end
      end
    end

    def migrate_viewmodel!(view_name, source_version, view_hash, references)
      path = @paths[view_name]
      return false unless path

      required_version, current_version = @versions[view_name]
      return false if source_version == current_version

      # We assume that an unspecified source version is the same as the required
      # version (i.e. the version demanded by the client request).
      unless source_version.nil? || source_version == required_version
        raise ViewModel::Migration::UnspecifiedVersionError.new(view_name, source_version)
      end

      path.each do |migration|
        migration.up(view_hash, references)
      end

      view_hash[ViewModel::VERSION_ATTRIBUTE] = current_version

      true
    end
  end

  # down migrations find a reverse path from the current schema version to the
  # specific version requested by the client.
  class DownMigrator < Migrator
    private

    def migrate_viewmodel!(view_name, source_version, view_hash, references)
      path = @paths[view_name]
      return false unless path

      # In a serialized output, the source version should always be the present
      # and the current version, unless already modified by a parent migration
      required_version, current_version = @versions[view_name]
      return false if source_version == required_version

      unless source_version == current_version
        raise ViewModel::Migration::UnspecifiedVersionError.new(view_name, source_version)
      end

      path.reverse_each do |migration|
        migration.down(view_hash, references)
      end

      view_hash[ViewModel::VERSION_ATTRIBUTE] = required_version

      true
    end
  end
end
