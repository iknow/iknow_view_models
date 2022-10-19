# frozen_string_literal: true

require 'view_model/migration'
require 'view_model/migrator'

require 'rgl/adjacency'
require 'rgl/dijkstra'

module ViewModel::MigratableView
  extend ActiveSupport::Concern

  class_methods do
    def inherited(base)
      super
      base.initialize_as_migratable_view
    end

    def initialize_as_migratable_view
      @migrations_lock   = Monitor.new
      @migration_classes = {}
      @migration_paths   = {}
      @previous_names    = {}
      @realized_paths    = true
      @versioned_view_names = nil
    end

    def migration_path(from:, to:)
      @migrations_lock.synchronize do
        realize_paths! unless @realized_paths

        migrations = @migration_paths.fetch([from, to]) do
          raise ViewModel::Migration::NoPathError.new(self, from, to)
        end

        migrations
      end
    end

    def versioned_view_names
      @migrations_lock.synchronize do
        cache_versioned_view_names! if @versioned_view_names.nil?
        @versioned_view_names
      end
    end

    def view_name_at_version(version)
      versioned_view_names.fetch(version) do
        raise ViewModel::Migration::NoSuchVersionError.new(self, version)
      end
    end

    protected

    def migration_class(from, to)
      @migration_classes.fetch([from, to]) do
        raise ViewModel::Migration::NoPathError.new(self, from, to)
      end
    end

    def known_schema_versions
      @migrations_lock.synchronize do
        realize_paths! unless @realized_paths
        versions = Set.new([schema_version])
        @migration_paths.each_key do |from, to|
          versions << from << to
        end
        versions.to_a.sort
      end
    end

    private

    # Define a migration on this viewmodel
    def migrates(from:, to:, inherit: nil, at: nil, &block)
      @migrations_lock.synchronize do
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

        if migration_class.renamed?
          old_name = migration_class.renamed_from
          if @previous_names.has_key?(from)
            raise ArgumentError.new("Inconsistent previous naming for version #{from}") if @previous_names[from] != old_name
          else
            @previous_names[from] = old_name
          end
        end

        const_set(:"Migration_#{from}_To_#{to}", migration_class)
        @migration_classes[[from, to]] = migration_class

        @versioned_view_names = nil
        @realized_paths = false
      end
    end

    # Internal: find and record possible paths to the current schema version.
    def realize_paths!
      @migration_paths.clear

      graph = RGL::DirectedAdjacencyGraph.new

      # Add a vertex for the current version, in case no edges reach it
      graph.add_vertex(self.schema_version)

      # Add edges backwards, as we care about paths from the latest version
      @migration_classes.each_key do |from, to|
        graph.add_edge(to, from)
      end

      paths = graph.dijkstra_shortest_paths(Hash.new { 1 }, self.schema_version)

      paths.each do |target_version, path|
        next if path.nil? || path.length == 1

        # Store the path forwards rather than backwards
        path_migration_classes = path.reverse.each_cons(2).map do |from, to|
          @migration_classes.fetch([from, to])
        end

        key = [target_version, schema_version]

        @migration_paths[key] = path_migration_classes.map(&:new)
      end

      @realized_paths = true
    end

    def cache_versioned_view_names!
      name = self.view_name
      @versioned_view_names =
        known_schema_versions.reverse_each.to_h do |version|
          if @previous_names.has_key?(version)
            name = @previous_names[version]
          end
          [version, name]
        end
    end
  end
end
