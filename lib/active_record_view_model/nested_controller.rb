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
    id_param = params[id_param_name]
    raise ArgumentError.new("Missing model id: '#{id_param_name}'") if id_param.nil?
    id_param
  end

  def associated_id
    id_param_name = association_name.singularize + "_id"
    id_param = params[id_param_name]
    raise ArgumentError.new("Missing model id: '#{id_param_name}'") if id_param.nil?
    id_param
  end

  included do
    delegate :owner_viewmodel, :association_name, to: :class
  end

  class_methods do
    attr_accessor :owner_viewmodel, :association_name
  end
end
