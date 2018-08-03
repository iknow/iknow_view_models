# frozen_string_literal: true

# Controller mixin for accessing a root ViewModel which can be accessed
# individually by a parent model. Enabled by calling `nested_in :parent, as:
# :child` on the viewmodel controller

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

  def show_associated(scope: nil, serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    show_association(scope: scope, serialize_context: serialize_context)
  end

  def create_associated(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    write_association(serialize_context: serialize_context, deserialize_context: deserialize_context)
  end

  def destroy_associated(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    destroy_association(false, serialize_context: serialize_context, deserialize_context: deserialize_context)
  end
end
