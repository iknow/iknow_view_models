require 'active_record_view_model/nested_controller_base'
# Controller for accessing a ViewModel which is necessarily owned in a collection by a parent model.

# Contributes the following routes:
# PUT    /parents/:parent_id/children            #append  -- deserialize (possibly existing) children and append to collection
# POST   /parents/:parent_id/children            #create  -- deserialize (possibly existing) children, replacing existing collection
# GET    /parents/:parent_id/children            #index   -- list collection
# DELETE /parents/:parent_id/children/:child_id  #disassociate -- delete relationship between parent/child (possibly garbage-collecting child)
# DELETE /parents/:parent_id/children            #disassociate_all -- delete relationship from parent to all children

## Inherits the following routes to manipulate children directly:
# POST   /children      #create -- create or update without parent
# GET    /children/:id  #show
# DELETE /children/:id  #destroy
module ActiveRecordViewModel::CollectionNestedController
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::NestedControllerBase

  # List items associated with the owner
  def index(&block)
    show_association(&block)
  end

  # Deserialize items of the associated type and associate them with the owner,
  # replacing previously associated items.
  def create
    if owner_viewmodel_id(required: false).nil?
      super
    else
      write_association
    end
  end

  def disassociate_all
    destroy_association(true)
  end

  # Deserialize items of the associated type and append them to the owner's
  # collection.
  def append
    ser_context = serialize_view_context
    owner_viewmodel.transaction do
      update_hash, refs = parse_viewmodel_updates

      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, serialize_context: serialize_view_context)

      assoc_view = owner_view.append_associated(association_name,
                                                update_hash,
                                                references: refs,
                                                deserialize_context: deserialize_view_context)

      ViewModel.preload_for_serialization(assoc_view, serialize_context: ser_context)
      render_viewmodel(assoc_view, serialize_context: ser_context)
    end
  end

  def disassociate
    ser_context = serialize_view_context
    owner_viewmodel.transaction do
      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, serialize_context: ser_context)
      associated_view = owner_view.find_associated(association_name, associated_id, eager_include: false, serialize_context: ser_context)
      owner_view.delete_associated(association_name, associated_view, deserialize_context: deserialize_view_context)
      render_viewmodel(nil)
    end
  end
end
