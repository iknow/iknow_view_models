# frozen_string_literal: true

class ViewModel
  class Migrator
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

    def migrate!(node, references:)
      case node
      when Hash
        if (type = node[ViewModel::TYPE_ATTRIBUTE])
          version = node[ViewModel::VERSION_ATTRIBUTE]

          if migrate_viewmodel!(type, version, node, references)
            node[ViewModel::MIGRATED_ATTRIBUTE] = true
          end
        end

        node.each_value do |child|
          migrate!(child, references: references)
        end
      when Array
        node.each { |child| migrate!(child, references: references) }
      end
    end

    private

    def migrate_viewmodel!(_view_name, _version, _view_hash, _references)
      raise RuntimeError.new('abstract method')
    end
  end

  class UpMigrator < Migrator
    private

    def migrate_viewmodel!(view_name, source_version, view_hash, references)
      path = @paths[view_name]
      return false unless path

      # We assume that an unspecified source version is the same as the required
      # version.
      required_version, current_version = @versions[view_name]

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

    def migrate_viewmodel!(view_name, _, view_hash, references)
      path = @paths[view_name]
      return false unless path

      required_version, _current_version = @versions[view_name]

      path.reverse_each do |migration|
        migration.down(view_hash, references)
      end

      view_hash[ViewModel::VERSION_ATTRIBUTE] = required_version

      true
    end
  end
end
