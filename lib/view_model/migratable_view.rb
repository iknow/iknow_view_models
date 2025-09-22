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
    end

    def migration_path(from:, to:)
      @migrations_lock.synchronize do
        unless @migration_paths.has_key?(to)
          @migration_paths[to] = compute_migration_paths(to)
        end

        migrations = @migration_paths[to].fetch(from) do
          raise ViewModel::Migration::NoPathError.new(self, from, to)
        end

        migrations
      end
    end

    protected

    def migration_class(from, to)
      @migration_classes.fetch([from, to]) do
        raise ViewModel::Migration::NoPathError.new(self, from, to)
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

        const_set(:"Migration_#{from}_To_#{to}", migration_class)
        @migration_classes[[from, to]] = migration_class

        clear_migration_paths!
      end
    end

    def clear_migration_paths!
      @migrations_lock.synchronize do
        @migration_paths.clear
      end
    end

    # Internal: find and record possible paths to the current schema version.
    def compute_migration_paths(to_version)
      unless to_version <= self.schema_version
        raise RuntimeError.new("Cannot compute path to future version '#{to_version}'")
      end

      graph = RGL::DirectedAdjacencyGraph.new

      # Add a vertex for the destination version, in case no edges reach it
      graph.add_vertex(to_version)

      # Add edges backwards, as we care about paths from the latest version
      @migration_classes.each_key do |from, to|
        graph.add_edge(to, from)
      end

      paths = graph.dijkstra_shortest_paths(Hash.new { 1 }, to_version)

      result = {}

      paths.each do |target_version, path|
        next if path.nil? || path.length == 1

        # Store the path forwards rather than backwards
        path_migration_classes = path.reverse.each_cons(2).map do |from, to|
          @migration_classes.fetch([from, to])
        end

        result[target_version] = path_migration_classes.map(&:new)
      end

      result
    end
  end
end
