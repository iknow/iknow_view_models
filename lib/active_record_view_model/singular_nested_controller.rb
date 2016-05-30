# Controller for accessing a ViewModel which is necessarily owned in a collection by a parent model.

# Contributes the following routes:
# POST   /parents/:parent_id/child   #create  -- deserialize (possibly existing) child, replacing existing child
# GET    /parents/:parent_id/child   #show    -- show child of parent
# DELETE /parents/:parent_id/child   #destroy -- delete relationship between parent and its child (possibly garbage-collecting child)

## Inherits the following routes to manipulate children directly:
# POST   /children      #create -- create or update without parent
# GET    /children/:id  #show
# DELETE /children/:id  #destroy

require 'active_record_view_model/nested_controller_base'
module ActiveRecordViewModel::SingularNestedController
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::Controller
  include ActiveRecordViewModel::NestedControllerBase

  def index
    raise ArgumentError.new("Index unavailable for nested view")
  end

  def show
    if owner_viewmodel_id(required: false).nil?
      super
    else
      show_association
    end
  end

  def create
    if owner_viewmodel_id(required: false).nil?
      super
    else
      write_association
    end
  end

  def destroy
    if owner_viewmodel_id(required: false).nil?
      super
    else
      destroy_association(false)
    end
  end
end
