# frozen_string_literal: true

require 'view_model/active_record/nested_controller_base'

# Controller mixin for accessing a root ViewModel which can be accessed in a
# collection by a parent model. Enabled by calling `nested_in :parent, as:
# :children` on the viewmodel controller

# Contributes the following routes:
# PUT    /parents/:parent_id/children            #append  -- deserialize (possibly existing) children and append to collection
# POST   /parents/:parent_id/children            #replace -- deserialize (possibly existing) children, replacing existing collection
# GET    /parents/:parent_id/children            #index_associated -- list collection
# DELETE /parents/:parent_id/children/:child_id  #disassociate -- delete relationship between parent/child (possibly garbage-collecting child)
# DELETE /parents/:parent_id/children            #disassociate_all -- delete relationship from parent to all children

## Inherits the following routes to manipulate children directly:
# POST   /children      #create -- create or update without parent
# GET    /children      #index  -- list all child models regardless of parent
# GET    /children/:id  #show
# DELETE /children/:id  #destroy
module ViewModel::ActiveRecord::CollectionNestedController
  extend ActiveSupport::Concern
  include ViewModel::ActiveRecord::NestedControllerBase

  def index_associated(scope: nil, serialize_context: new_serialize_context)
    show_association(scope: scope, serialize_context: serialize_context)
  end

  # Deserialize items of the associated type and associate them with the owner,
  # replacing previously associated items.
  def replace(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    write_association(serialize_context: serialize_context, deserialize_context: deserialize_context)
  end

  def disassociate_all(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    destroy_association(true, serialize_context: serialize_context, deserialize_context: deserialize_context)
  end

  # Deserialize items of the associated type and append them to the owner's
  # collection.
  def append(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    assoc_view = nil
    pre_rendered = owner_viewmodel.transaction do
      update_hash, refs = parse_viewmodel_updates

      before = parse_relative_position(:before)
      after  = parse_relative_position(:after)

      if before && after
        raise ViewModel::DeserializationError::InvalidSyntax.new("Can not provide both `before` and `after` anchors for a collection append")
      end

      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, serialize_context: serialize_context)

      assoc_view = owner_view.append_associated(association_name,
                                                update_hash,
                                                references: refs,
                                                before:     before,
                                                after:      after,
                                                deserialize_context: deserialize_context)

      child_context = owner_view.context_for_child(association_name, context: serialize_context)
      ViewModel.preload_for_serialization(assoc_view, serialize_context: child_context)
      prerender_viewmodel(assoc_view, serialize_context: child_context)
    end
    render_json_string(pre_rendered)
    assoc_view
  end

  def disassociate(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    owner_viewmodel.transaction do
      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, serialize_context: serialize_context)
      owner_view.delete_associated(association_name, associated_id, deserialize_context: deserialize_context)
      render_viewmodel(nil)
    end
  end

  private

  def parse_relative_position(name)
    id = parse_uuid_param(name, default: nil)

    if id
      if association_data.polymorphic?
        type_name = parse_param("#{name}_type")
        type = association_data.viewmodel_class_for_name(type_name)
        if type.nil?
          raise ViewModel::DeserializationError::InvalidAssociationType.new(association_data.association_name.to_s, type_name)
        end
      else
        type = owner_viewmodel.viewmodel_class
      end

      ViewModel::Reference.new(type, id)
    else
      nil
    end
  end
end
