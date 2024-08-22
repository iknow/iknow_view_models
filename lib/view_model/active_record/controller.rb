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
    viewmodel_ids = parse_param(
      :id, with: IknowParams::Serializer::ArrayOf.new(ViewmodelIdSerializer, allow_singleton: true))

    viewmodel_class.transaction do
      views = viewmodel_class.find(viewmodel_ids, eager_include: false)
      views.each do |view|
        view.destroy!(deserialize_context: deserialize_context)
      end
    end
    render_viewmodel(nil, serialize_context: serialize_context)
  end

  private

  # Viewmodel ids are permitted to be either integers or strings
  class ViewmodelIdSerializer < IknowParams::Serializer
    def initialize
      super(::Object)
    end

    def load(val)
      case val
      when ::Integer, ::String
        val
      else
        raise IknowParams::Serializer::LoadError.new(
                "Incorrect type for #{self.class.name}: #{val.inspect}:#{val.class.name}")
      end
    end

    set_singleton!
    json_value!
  end

  def viewmodel_id
    parse_param(:id, with: ViewmodelIdSerializer)
  end
end
