require 'view_model/active_record/controller_base'

# Controller for accessing an ViewModel::ActiveRecord
# Provides for the following routes:
# POST   /models      #create -- create or update one or more models
# GET    /models      #index
# GET    /models/:id  #show
# DELETE /models/:id  #destroy

module ViewModel::ActiveRecord::Controller
  extend ActiveSupport::Concern
  include ViewModel::ActiveRecord::ControllerBase

  def show(scope: nil, serialize_context: new_serialize_context)
    view = nil
    pre_rendered = viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, scope: scope, serialize_context: serialize_context)
      view = yield(view) if block_given?
      prerender_viewmodel(view, serialize_context: serialize_context)
    end
    render_json_string(pre_rendered)
    view
  end

  def index(scope: nil, serialize_context: new_serialize_context)
    views = nil
    pre_rendered = viewmodel.transaction do
      views = viewmodel.load(scope: scope, serialize_context: serialize_context)
      views = yield(views) if block_given?
      prerender_viewmodel(views, serialize_context: serialize_context)
    end
    render_json_string(pre_rendered)
    views
  end

  def create(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    update_hash, refs = parse_viewmodel_updates

    view = nil
    pre_rendered = viewmodel.transaction do
      view = viewmodel.deserialize_from_view(update_hash, references: refs, deserialize_context: deserialize_context)

      serialize_context.add_includes(deserialize_context.updated_associations)

      ViewModel.preload_for_serialization(view, serialize_context: serialize_context)
      prerender_viewmodel(view, serialize_context: serialize_context)
    end
    render_json_string(pre_rendered)
    view
  end

  def destroy(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, eager_include: false, serialize_context: serialize_context)
      view.destroy!(deserialize_context: deserialize_context)
    end
    render_viewmodel(nil)
  end

  class_methods do
    def nested_in(owner, as:)
      if as.to_s.singularize == as.to_s
        include ViewModel::ActiveRecord::SingularNestedController
      else
        include ViewModel::ActiveRecord::CollectionNestedController
      end

      unless owner.is_a?(Class) && owner < ViewModel::Record
        owner = ViewModel::Registry.for_view_name(owner.to_s.camelize)
      end

      self.owner_viewmodel = owner
      raise ArgumentError.new("Could not find owner ViewModel class '#{owner_name}'") if owner_viewmodel.nil?
      self.association_name = as
    end
  end

  included do
    etag { self.viewmodel.deep_schema_version }
  end

  private

  def viewmodel_id
    parse_param(:id)
  end

end
