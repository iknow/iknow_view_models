# Controller for accessing a ViewModel which is necessarily owned in a collection by a parent model.

# Contributes the following routes:
# POST   /parents/:parent_id/child   #create  -- deserialize (possibly existing) child, replacing existing child
# GET    /parents/:parent_id/child   #show_association    -- show child of parent
# DELETE /parents/:parent_id/child   #destroy -- delete relationship between parent and its child (possibly garbage-collecting child)

## Inherits the following routes to manipulate children directly:
# POST   /children      #create -- create or update without parent
# GET    /children/:id  #show
# DELETE /children/:id  #destroy

require 'view_model/active_record/nested_controller_base'
module ViewModel::ActiveRecord::SingularNestedController
  extend ActiveSupport::Concern
  include ViewModel::ActiveRecord::NestedControllerBase

  def index
    raise ArgumentError.new('Index unavailable for nested view')
  end

  def create(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    if owner_viewmodel_id(required: false).nil?
      super(serialize_context: serialize_context, deserialize_context: deserialize_context)
    else
      write_association(serialize_context: serialize_context, deserialize_context: deserialize_context)
    end
  end

  def destroy(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context)
    if owner_viewmodel_id(required: false).nil?
      super(serialize_context: serialize_context, deserialize_context: deserialize_context)
    else
      destroy_association(false, serialize_context: serialize_context, deserialize_context: deserialize_context)
    end
  end
end
