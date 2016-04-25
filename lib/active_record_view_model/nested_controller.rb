# Controller for accessing a ViewModel which is necessarily owned by a parent model.

# Expects the following routes:
# GET    /parents/:parent_id/children       #index
# POST   /parents/:parent_id/children       #create
# GET    /children/:id                      #show
# PATCH  /children/:id                      #update
# PUT    /children/:id                      #update
# DELETE /children/:id                      #destroy

module ActiveRecordViewModel::NestedController
  extend ActiveSupport::Concern

  # List items associated with the owner
  def index
    view_context = serialize_view_context
    owner_viewmodel.transaction do
      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, view_context: view_context)
      associated_views = owner_view.load_associated(association_name)

      render_viewmodel(associated_views, view_context: view_context)
    end
  end

  # Deserialize an item of the associated type and associate it with the owner.
  # For a collection association, this appends to the collection.
  def create
    owner_viewmodel.transaction do
      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, view_context: serialize_view_context)

      update_hash = params[:data]

      unless _valid_update_hash?(update_hash)
        raise BadRequest.new('Empty or invalid data submitted')
      end

      assoc_view = owner_view.append_associated(association_name, update_hash, view_context: deserialize_view_context)

      render_viewmodel(assoc_view, view_context: serialize_view_context)
    end
  end

  # Change the contents of the association.
  # Same as setting an entity with recursive edit.
  def update
    owner_viewmodel.transaction do
      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, view_context: serialize_view_context)

      assoc_view = owner_view.deserialize_associated(association_name, udpate_hash, view_context, deserialize_view_context)

      render_viewmodel(assoc_view, view_context, serialize_view_context)
    end
  end


  # Destroy association, not either of the records
  # Same as setting association to `nil` in recursive edit
  def destroy

  end

  private

  def owner_viewmodel_id
    id_param_name = owner_viewmodel.view_name + '_id'
    parse_integer_param(id_param_name)
  end

  def associated_id
    id_param_name = association_name.singularize + '_id'
    parse_integer_param(id_param_name)
  end

  included do
    delegate :owner_viewmodel, :association_name, to: :class
  end

  class_methods do
    attr_accessor :owner_viewmodel, :association_name
  end
end
