require 'active_record_view_model/controller_base'
module ActiveRecordViewModel::NestedControllerBase
  extend ActiveSupport::Concern

  protected

  def show_association
    ser_context = serialize_view_context
    owner_viewmodel.transaction do
      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, serialize_context: ser_context)
      owner_view.visible!(context: ser_context)
      associated_views = owner_view.load_associated(association_name)

      render_viewmodel(associated_views, serialize_context: ser_context)
    end
  end

  def write_association
    ser_context = serialize_view_context
    owner_viewmodel.transaction do
      update_hash, refs = parse_viewmodel_updates

      updated_owner_view = owner_viewmodel.deserialize_from_view(owner_update_hash(update_hash),
                                                                 references: refs,
                                                                 deserialize_context: deserialize_view_context)

      association_view = updated_owner_view.read_association(association_name)

      ViewModel.preload_for_serialization(association_view, serialize_context: ser_context)
      render_viewmodel(association_view, serialize_context: ser_context)
    end
  end

  def destroy_association(collection)
    ser_context = serialize_view_context
    owner_viewmodel.transaction do
      empty_update = collection ? [] : nil

      owner_viewmodel.deserialize_from_view(owner_update_hash(empty_update),
                                            deserialize_context: deserialize_view_context)

      render_viewmodel(empty_update, serialize_context: ser_context)
    end
  end

  def owner_update_hash(update)
    {
      ActiveRecordViewModel::ID_ATTRIBUTE   => owner_viewmodel_id,
      ActiveRecordViewModel::TYPE_ATTRIBUTE => owner_viewmodel.view_name,
      association_name.to_s                 => update
    }
  end

  def owner_viewmodel_id(required: true)
    id_param_name = owner_viewmodel.view_name.downcase + '_id'
    default = required ? {} : { default: nil }
    parse_integer_param(id_param_name, **default)
  end

  def associated_id(required: true)
    id_param_name = association_name.to_s.singularize + '_id'
    default = required ? {} : { default: nil }
    parse_integer_param(id_param_name, **default)
  end

  included do
    delegate :owner_viewmodel, :association_name, to: 'self.class'
  end

  module ClassMethods
    attr_accessor :owner_viewmodel, :association_name
  end
end