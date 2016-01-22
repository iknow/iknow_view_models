require 'active_record_view_model/controller_base'

module ActiveRecordViewModel::AssociationController
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::ControllerBase

  # List items associated with the target
  def index(**view_options)
    target_viewmodel.transaction do
      target_view = target_viewmodel.find(viewmodel_id, eager_include: false, **view_options)
      associated_views = target_view.load_associated(association_name, **view_options)

      render_viewmodel({ data: associated_views }, **view_options)
    end
  end

  # Deserialize items of the associated type and associate them with the target.
  # For a multiple association, can provide a single item to append to the
  # collection or an array of items to replace the collection.
  def create(**view_options)
    target_viewmodel.transaction do
      target_view = target_viewmodel.find(viewmodel_id, eager_include: false, **view_options)

      data = params[:data]

      unless data.present? && (data.is_a?(Hash) || data.is_a?(Array))
        raise BadRequest.new("Empty or invalid data submitted")
      end

      assoc_view = target_view.deserialize_associated(association_name, data)
      render_viewmodel({ data: associated_views }, **view_options)
    end
  end

  # Remove the association between the target and the provided item, garbage
  # collecting the item if specified as `dependent:` by the association.
  # Can't work for polymorphic associations.
  def destroy(**view_options)
    target_view = target_viewmodel.find(viewmodel_id, eager_include: false)

    # Is this really appropriate? These should all be in a transaction.
    associated_view = target_view.find_associated(association_name, associated_id, eager_include: false)
    target_view.delete_associated(association_name, associated_view, **view_options)

    render_viewmodel({ data: nil })
  end

  private

  def viewmodel_id
    id_param_name = target_viewmodel.model_class.name.underscore + "_id"
    id_param = params[id_param_name]
    raise "No!" if id_param.nil?
    id_param
  end

  def associated_id
    id_param_name = association_name.singularize + "_id"
    id_param = params[id_param_name]
    raise "No!" if id_param.nil?
    id_param
  end

  included do
    delegate :target_viewmodel, :association_name, to: :class
  end

  class_methods do
    attr_accessor :target_viewmodel, :association_name
  end
end
