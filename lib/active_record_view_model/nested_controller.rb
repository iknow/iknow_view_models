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
    owner_viewmodel.transaction do
      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, **view_options)
      associated_views = owner_view.load_associated(association_name)

      render_viewmodel({ data: associated_views }, **view_options)
    end
  end

  # Deserialize an item of the associated type and associate it with the owner.
  # For a collection association, this appends to the collection.
  def create
    owner_viewmodel.transaction do
      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, **view_options)

      data = params[:data]
      raise BadRequest.new("Empty or invalid data submitted") unless data.present?

      assoc_view = owner_view.deserialize_associated(association_name, data)
      render_viewmodel({ data: assoc_view }, **view_options)
    end
  end

  private

  def owner_viewmodel_id
    id_param_name = owner_viewmodel.model_class.name.underscore + "_id"
    parse_integer_param(id_param_name)
  end

  def associated_id
    id_param_name = association_name.singularize + "_id"
    parse_integer_param(id_param_name)
  end

  included do
    delegate :owner_viewmodel, :association_name, to: :class
  end

  class_methods do
    attr_accessor :owner_viewmodel, :association_name
  end
end
