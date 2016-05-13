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
    context = serialize_view_context
    owner_viewmodel.transaction do
      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, serialize_context: context)
      associated_views = owner_view.load_associated(association_name)

      render_viewmodel(associated_views, serialize_context: context)
    end
  end

  # Deserialize an item of the associated type and associate it with the owner.
  # For a collection association, this appends to the collection.
  def create
    owner_viewmodel.transaction do
      update_hash, refs = parse_viewmodel_updates

      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, serialize_context: serialize_view_context)

      assoc_view = owner_view.append_associated(association_name,
                                                update_hash,
                                                references: refs,
                                                deserialize_context: deserialize_view_context)

      render_viewmodel(assoc_view, serialize_context: serialize_view_context)
    end
  end

  # Change the contents of the association.
  # Same as setting an entity with recursive edit.
  def update
    update_hash, refs = parse_viewmodel_updates
    update_association(update_hash, refs)
  end


  # Destroy association. Same as setting association to `nil` in recursive edit
  def destroy
    # TODO not appropriate for collections; need proper error
    update_association(nil, {})
  end

  private

  def update_association(update_hash, refs)
    owner_viewmodel.transaction do
      owner_update_hash = { ActiveRecordViewModel::ID_ATTRIBUTE   => owner_viewmodel_id,
                            ActiveRecordViewModel::TYPE_ATTRIBUTE => owner_viewmodel.view_name,
                            association_name.to_s                 => update_hash }

      updated_owner_view = owner_viewmodel.deserialize_from_view(owner_update_hash,
                                                                 references: refs,
                                                                 deserialize_context: deserialize_view_context)

      association_view = updated_owner_view.read_association(association_name)
      render_viewmodel(association_view, serialize_context: serialize_view_context)
    end
  end

  def owner_viewmodel_id
    id_param_name = owner_viewmodel.view_name.downcase + '_id'
    parse_integer_param(id_param_name)
  end

  def associated_id
    id_param_name = association_name.singularize + '_id'
    parse_integer_param(id_param_name)
  end

  included do
    delegate :owner_viewmodel, :association_name, to: 'self.class'
  end

  module ClassMethods
    attr_accessor :owner_viewmodel, :association_name
  end
end
