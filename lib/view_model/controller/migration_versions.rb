# frozen_string_literal: true

module ViewModel::Controller::MigrationVersions
  extend ActiveSupport::Concern

  MIGRATION_VERSION_HEADER = 'X-ViewModel-Versions'

  def migration_versions
    @migration_versions ||=
      begin
        versions = specified_migration_versions.dup

        unless ViewModel::Config.strict_migration_versions
          # Ignore the current version. This allows skipping migrations if only
          # current versions are requested. Can't be ignored when strict
          # migrations are enabled, since we need to walk the tree to assert
          # that all visited types are mentioned.
          versions.reject! do |viewmodel_class, required_version|
            viewmodel_class.schema_version == required_version
          end
        end

        versions.freeze
      end
  end

  def specified_migration_versions
    @specified_migration_versions ||=
      begin
        version_spec =
          if params.include?(:versions)
            params[:versions]
          elsif request.headers.include?(MIGRATION_VERSION_HEADER)
            begin
              JSON.parse(request.headers[MIGRATION_VERSION_HEADER])
            rescue JSON::ParserError
              raise ViewModel::Error.new(status: 400, detail: "Invalid JSON in #{MIGRATION_VERSION_HEADER}")
            end
          else
            {}
          end

        versions =
          IknowParams::Parser.parse_value(
            version_spec,
            with: IknowParams::Serializer::HashOf.new(
              IknowParams::Serializer::String, IknowParams::Serializer::Integer))

        migration_versions = {}

        versions.each do |view_name, required_version|
          viewmodel_class = ViewModel::Registry.for_view_name(view_name)
          migration_versions[viewmodel_class] = required_version
        rescue ViewModel::DeserializationError::UnknownView
          # Ignore requests to migrate types that no longer exist
          next
        end

        migration_versions.freeze
      end
  end
end
