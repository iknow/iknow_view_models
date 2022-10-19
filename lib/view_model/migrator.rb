# frozen_string_literal: true

class ViewModel
  class Migrator
    EXCLUDE_FROM_MIGRATION = '_exclude_from_migration'

    class << self
      def migrated_deep_schema_version(viewmodel_class, client_versions, include_referenced: true)
        deep_schema_version = viewmodel_class.deep_schema_version(include_referenced: include_referenced)

        if client_versions.present?
          deep_schema_version = deep_schema_version.dup

          client_versions.each do |vm_class, client_version|
            name = vm_class.view_name
            name_at_client_version = vm_class.view_name_at_version(client_version)
            if deep_schema_version.has_key?(name)
              deep_schema_version.delete(name)
              deep_schema_version[name_at_client_version] = client_version
            end
          end
        end

        deep_schema_version
      end
    end

    MigrationDetail = Value.new(:viewmodel_class, :path, :client_name, :client_version) do
      def current_name
        viewmodel_class.view_name
      end

      def current_version
        viewmodel_class.schema_version
      end
    end

    def initialize(client_versions)
      @migrations = client_versions.each_with_object({}) do |(viewmodel_class, client_version), h|
        next if client_version == viewmodel_class.schema_version

        path = viewmodel_class.migration_path(from: client_version, to: viewmodel_class.schema_version)
        client_name = viewmodel_class.view_name_at_version(client_version)
        detail = MigrationDetail.new(viewmodel_class, path, client_name, client_version)

        # Index by the name we expect to see in the tree to be migrated (client
        # name for up, current name for down)
        h[source_name(detail)] = detail
      end
    end

    def migrate!(serialization)
      migrate_tree!(serialization, references: serialization['references'] || {})
      GarbageCollection.garbage_collect_references!(serialization)
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

    # What name is expected for a given view in the to-be-migrated source tree.
    # Varies between up and down migration.
    def source_name(_migration_detail)
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

    def migrate_viewmodel!(source_name, source_version, view_hash, references)
      migration = @migrations[source_name]
      return false unless migration

      # We assume that an unspecified source version is the same as the required
      # client version.
      unless source_version.nil? || source_version == migration.client_version
        raise ViewModel::Migration::UnspecifiedVersionError.new(source_name, source_version)
      end

      migration.path.each do |step|
        step.up(view_hash, references)
      end

      view_hash[ViewModel::TYPE_ATTRIBUTE]    = migration.current_name
      view_hash[ViewModel::VERSION_ATTRIBUTE] = migration.current_version

      true
    end

    def source_name(migration_detail)
      migration_detail.client_name
    end
  end

  # down migrations find a reverse path from the current schema version to the
  # specific version requested by the client.
  class DownMigrator < Migrator
    private

    def migrate_viewmodel!(source_name, source_version, view_hash, references)
      migration = @migrations[source_name]
      return false unless migration

      # In a serialized output, the source version should always be present and
      # the current version, unless already modified by a parent migration (in
      # which case there's nothing to be done).
      if source_version == migration.client_version
        return false
      elsif source_version != migration.current_version
        raise ViewModel::Migration::UnspecifiedVersionError.new(source_name, source_version)
      end

      migration.path.reverse_each do |step|
        step.down(view_hash, references)
      end

      view_hash[ViewModel::TYPE_ATTRIBUTE]    = migration.client_name
      view_hash[ViewModel::VERSION_ATTRIBUTE] = migration.client_version

      true
    end

    def source_name(migration_detail)
      migration_detail.current_name
    end
  end
end
