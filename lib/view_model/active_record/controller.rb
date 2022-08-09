# frozen_string_literal: true

require 'view_model/active_record/controller_base'
require 'view_model/active_record/collection_nested_controller'
require 'view_model/active_record/singular_nested_controller'

# Controller for accessing an ViewModel::ActiveRecord
# Provides for the following routes:
# POST   /models      #create -- create or update one or more models
# GET    /models      #index
# GET    /models/:id  #show
# DELETE /models/:id  #destroy

module ViewModel::ActiveRecord::Controller
  extend ActiveSupport::Concern
  include ViewModel::ActiveRecord::ControllerBase
  include ViewModel::ActiveRecord::CollectionNestedController
  include ViewModel::ActiveRecord::SingularNestedController

  MIGRATION_VERSION_HEADER = 'X-ViewModel-Versions'

  def show(scope: nil, viewmodel_class: self.viewmodel_class, serialize_context: new_serialize_context(viewmodel_class: viewmodel_class))
    view = nil
    pre_rendered = viewmodel_class.transaction do
      view = viewmodel_class.find(viewmodel_id, scope: scope)
      view = yield(view) if block_given?
      prerender_viewmodel(view, serialize_context: serialize_context)
    end
    render_json_string(pre_rendered)
    view
  end

  def index(scope: nil, viewmodel_class: self.viewmodel_class, serialize_context: new_serialize_context(viewmodel_class: viewmodel_class))
    views = nil
    pre_rendered = viewmodel_class.transaction do
      views = viewmodel_class.load(scope: scope)
      views = yield(views) if block_given?
      prerender_viewmodel(views, serialize_context: serialize_context)
    end
    render_json_string(pre_rendered)
    views
  end

  def create(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    update_hash, refs = parse_viewmodel_updates

    view = nil
    pre_rendered = viewmodel_class.transaction do
      view = viewmodel_class.deserialize_from_view(update_hash, references: refs, deserialize_context: deserialize_context)
      ViewModel.preload_for_serialization(view)
      view = yield(view) if block_given?
      prerender_viewmodel(view, serialize_context: serialize_context)
    end
    render_json_string(pre_rendered)
    view
  end

  def destroy(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    viewmodel_class.transaction do
      view = viewmodel_class.find(viewmodel_id, eager_include: false)
      view.destroy!(deserialize_context: deserialize_context)
    end
    render_viewmodel(nil)
  end

  included do
    etag { migrated_deep_schema_version }
  end

  def parse_viewmodel_updates
    super.tap do |update_hash, refs|
      if migration_versions.present?
        migrator = ViewModel::UpMigrator.new(migration_versions)
        migrator.migrate!({ 'data' => update_hash, 'references' => refs })
      end
    end
  end

  def prerender_viewmodel(...)
    super do |jbuilder|
      yield(jbuilder) if block_given?

      # migrate the resulting structure before it's serialized to a json string
      if migration_versions.present?
        tree = jbuilder.attributes!
        migrator = ViewModel::DownMigrator.new(migration_versions)
        migrator.migrate!(tree)
      end
    end
  end

  private

  def viewmodel_id
    parse_param(:id)
  end

  def migration_versions
    @migration_versions ||=
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
          viewmodel_class = ViewModel::Registry.for_view_name(view_name, version: required_version)

          if viewmodel_class.schema_version != required_version
            if migration_versions.has_key?(viewmodel_class) && migration_versions[viewmodel_class] != required_version
              raise ViewModel::Error.new(
                      status: 400,
                      code: 'ViewModel.InconsistentMigration',
                      detail: "Viewmodel #{viewmodel_class.view_name} specified twice with different versions (as '#{view_name}')")
            else
              migration_versions[viewmodel_class] = required_version
            end
          end
        rescue ViewModel::DeserializationError::UnknownView
          # Ignore requests to migrate types that no longer exist
          next
        end

        migration_versions.freeze
      end
  end

  def migrated_deep_schema_version
    ViewModel::Migrator.migrated_deep_schema_version(viewmodel_class, migration_versions, include_referenced: true)
  end
end
