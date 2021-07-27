# frozen_string_literal: true

# Controller mixin for accessing a root ViewModel which can be accessed
# individually by a parent model.

# Contributes the following routes:
# POST   /parents/:parent_id/child   #create_associated  -- deserialize (possibly existing) child, replacing existing child
# GET    /parents/:parent_id/child   #show_associated    -- show child of parent
# DELETE /parents/:parent_id/child   #destroy_associated -- delete relationship between parent and its child (possibly garbage-collecting child)

## Inherits the following routes to manipulate children directly:
# POST   /children      #create -- create or update without parent
# GET    /children      #index  -- list all child models regardless of parent
# GET    /children/:id  #show
# DELETE /children/:id  #destroy

require 'view_model/active_record/nested_controller_base'
module ViewModel::ActiveRecord::SingularNestedController
  extend ActiveSupport::Concern
  include ViewModel::ActiveRecord::NestedControllerBase

  def show_associated(scope: nil, serialize_context: new_serialize_context, lock_owner: nil, &block)
    show_association(scope: scope, serialize_context: serialize_context, lock_owner: lock_owner, &block)
  end

  def create_associated(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context, lock_owner: nil, &block)
    write_association(serialize_context: serialize_context, deserialize_context: deserialize_context, lock_owner: lock_owner, &block)
  end

  def destroy_associated(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context, lock_owner: nil)
    destroy_association(false, serialize_context: serialize_context, deserialize_context: deserialize_context, lock_owner: lock_owner)
  end
end
