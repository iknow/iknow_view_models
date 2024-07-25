# frozen_string_literal: true

require 'view_model/migration'
require 'view_model/migrator'

require 'rgl/adjacency'
require 'rgl/dijkstra'

module ViewModel::MigratableView
  extend ActiveSupport::Concern

  class_methods do
    def inherited(subclass)
      super
      subclass.initialize_as_migratable_view
    end

    def initialize_as_migratable_view
      @_migrations = MigrationSet.new(self)
    end

    delegate :migration_path, :migration_class, to: :@_migrations

    private

    # Helper for defining migrations exhaustively: migrations are defined in the
    # block, and then validated for completeness on its return.
    def migrations(&block)
      @_migrations.build!(&block)
    end
  end

  class MigrationSet
    def initialize(viewmodel)
      @viewmodel = viewmodel
      @migration_classes = {}
      @migration_paths = {}
      @unmigratable_versions = []
    end

    def build!(&block)
      instance_exec(&block)
      realize_paths!
    end

    def migration_path(from:, to:)
      @migration_paths.fetch([from, to]) do
        raise ViewModel::Migration::NoPathError.new(@viewmodel, from, to)
      end
    end

    def migration_class(from, to)
      @migration_classes.fetch([from, to]) do
        raise ViewModel::Migration::NoPathError.new(@viewmodel, from, to)
      end
    end

    private

    def migrates(from:, to:, inherit: nil, at: nil, &block)
      migration_superclass =
        if inherit
          raise ArgumentError.new('Must provide inherit version') unless at

          inherit.migration_class(at - 1, at)
        else
          ViewModel::Migration
        end

      builder = ViewModel::Migration::Builder.new(migration_superclass)
      builder.instance_exec(&block)

      migration_class = builder.build!

      @viewmodel.const_set(:"Migration_#{from}_To_#{to}", migration_class)
      @migration_classes[[from, to]] = migration_class
    end

    # Migration helper for common migration actions
    #
    # @param adding_fields list of fields added
    # @param removing_fields map of removed field to default value
    # @param renaming_fields
    #   map of name in the `from` version to the name in the `to` version
    # @param [Number] from from version
    # @param [Number] to to version
    def migrates_by(adding_fields: [], removing_fields: {}, renaming_fields: {}, from:, to:)
      adding_fields   = adding_fields.map(&:to_s)
      removing_fields = removing_fields.map { |(k, v)| [k.to_s, v.freeze] }
      renaming_fields = renaming_fields.map { |(k, v)| [k.to_s, v.to_s] }

      migrates from: from, to: to do
        down do |view, refs|
          # Hide newly created fields
          adding_fields.each { |f| view.delete(f) }

          # Add dummy values for removed fields
          removing_fields.each do |from_name, default_value|
            view[from_name] =
              if default_value.is_a?(Proc)
                default_value.call(view, refs)
              else
                default_value
              end
          end

          renaming_fields.each do |from_name, to_name|
            view[from_name] = view.delete(to_name)
          end
        end
        up do |view, _refs|
          # Silently drop updates to removed fields
          removing_fields.each_key do |from_name|
            view.delete(from_name)
          end

          renaming_fields.each do |from_name, to_name|
            view[to_name] = view.delete(from_name) if view.has_key?(from_name)
          end
        end
      end
    end

    # Define a simple migration for added optional fields, with a down-migration
    # removing them and an empty up-migration.
    def migrates_adding_fields(*fields, from:, to:)
      migrates_by(adding_fields: fields, from: from, to: to)
    end

    def migrates_renaming_fields(fields, from:, to:)
      migrates_by(renaming_fields: fields, from: from, to: to)
    end

    def no_migration_from!(version)
      @unmigratable_versions << version
    end

    # Internal: find and record possible paths to the current schema version.
    def realize_paths!
      graph = RGL::DirectedAdjacencyGraph.new

      # Add a vertex for the current version, in case no edges reach it
      graph.add_vertex(@viewmodel.schema_version)

      # Add edges backwards, as we care about paths from the latest version
      @migration_classes.each_key do |from, to|
        graph.add_edge(to, from)
      end

      paths = graph.dijkstra_shortest_paths(Hash.new { 1 }, @viewmodel.schema_version)

      paths.each do |target_version, path|
        next if path.nil? || path.length == 1

        # Store the path forwards rather than backwards
        path_migration_classes = path.reverse.each_cons(2).map do |from, to|
          @migration_classes.fetch([from, to])
        end

        key = [target_version, @viewmodel.schema_version]

        @migration_paths[key] = path_migration_classes.map(&:new)
      end

      # Ensure that all versions up to schema_version are either specified in a
      # migration, or declared as `no_migration!`. This does not imply that
      # every version is reachable, but merely that every version is mentioned.
      mentioned_versions = Set.new(@unmigratable_versions)
      paths.each_key { |target, _| mentioned_versions << target }

      (1 ... @viewmodel.schema_version).each do |target_version|
        unless mentioned_versions.include?(target_version)
          raise ViewModel::Migration::MigrationsIncompleteError.new(@viewmodel, target_version)
        end
      end
    end
  end
end
