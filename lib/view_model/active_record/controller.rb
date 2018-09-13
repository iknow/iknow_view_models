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

  def show(scope: nil, viewmodel_class: self.viewmodel_class, serialize_context: new_serialize_context(viewmodel_class: viewmodel_class))
    view = nil
    pre_rendered = viewmodel_class.transaction do
      view = viewmodel_class.find(viewmodel_id, scope: scope, serialize_context: serialize_context)
      view = yield(view) if block_given?
      prerender_viewmodel(view, serialize_context: serialize_context)
    end
    render_json_string(pre_rendered)
    view
  end

  def index(scope: nil, viewmodel_class: self.viewmodel_class, serialize_context: new_serialize_context(viewmodel_class: viewmodel_class))
    views = nil
    pre_rendered = viewmodel_class.transaction do
      views = viewmodel_class.load(scope: scope, serialize_context: serialize_context)
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

      view = yield(view) if block_given?

      ViewModel.preload_for_serialization(view, serialize_context: serialize_context)
      prerender_viewmodel(view, serialize_context: serialize_context)
    end
    render_json_string(pre_rendered)
    view
  end

  def destroy(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    viewmodel_class.transaction do
      view = viewmodel_class.find(viewmodel_id, eager_include: false, serialize_context: serialize_context)
      view.destroy!(deserialize_context: deserialize_context)
    end
    render_viewmodel(nil)
  end

  included do
    etag { self.viewmodel_class.deep_schema_version }
  end

  private

  def viewmodel_id
    parse_param(:id)
  end
end
