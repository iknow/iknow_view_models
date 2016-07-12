require 'active_record_view_model/controller_base'

# Controller for accessing an ActiveRecordViewModel
# Provides for the following routes:
# POST   /models      #create -- create or update one or more models
# GET    /models      #index
# GET    /models/:id  #show
# DELETE /models/:id  #destroy

module ActiveRecordViewModel::Controller
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::ControllerBase

  included do
    delegate :viewmodel, to: 'self.class'
  end

  def show(scope: nil, serialize_context: new_serialize_context)
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, scope: scope, serialize_context: serialize_context)
      view = yield(view) if block_given?
      render_viewmodel(view, serialize_context: serialize_context)
    end
  end

  def index(scope: nil, serialize_context: new_serialize_context)
    viewmodel.transaction do
      views = viewmodel.load(scope: scope, serialize_context: serialize_context)
      views = yield(views) if block_given?
      render_viewmodel(views, serialize_context: serialize_context)
    end
  end

  def create(serialize_context: nil, deserialize_context: new_deserialize_context)
    update_hash, refs = parse_viewmodel_updates

    return_array = update_hash.is_a?(Array)
    update_hash = Array.wrap(update_hash)

    viewmodel.transaction do
      root_updates, referenced_updates =
        ActiveRecordViewModel::UpdateData.parse_hashes(update_hash, refs)

      serialize_context ||= begin
        associations = root_updates
                         .map { |upd| upd.updated_associations(referenced_updates) }
                         .inject({}){ |acc, deps| acc.deep_merge(deps) }

        new_serialize_context(include: associations)
      end

      view = viewmodel.deserialize_from_update_data(
        root_updates, referenced_updates, deserialize_context: deserialize_context)

      unless return_array
        view = view.first
      end

      ViewModel.preload_for_serialization(view, serialize_context: serialize_context)
      render_viewmodel(view, serialize_context: serialize_context)
    end
  end

  def destroy(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, eager_include: false, serialize_context: serialize_context)
      view.destroy!(deserialize_context: deserialize_context)
      render_viewmodel(nil)
    end
  end

  class_methods do
    def nested_in(owner, as:)
      if as.to_s.singularize == as.to_s
        include ActiveRecordViewModel::SingularNestedController
      else
        include ActiveRecordViewModel::CollectionNestedController
      end

      self.owner_viewmodel = ActiveRecordViewModel.for_view_name(owner.to_s.camelize)
      raise ArgumentError.new("Could not find owner ViewModel class '#{owner_name}'") if owner_viewmodel.nil?
      self.association_name = as
    end
  end

  private

  def viewmodel_id
    parse_integer_param(:id)
  end

end
