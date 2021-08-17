# frozen_string_literal: true

require 'view_model/active_record/controller_base'

# Controller mixin defining machinery for accessing viewmodels nested under a
# parent. Used by Singular- and CollectionNestedControllers
module ViewModel::ActiveRecord::NestedControllerBase
  extend ActiveSupport::Concern

  protected

  def show_association(scope: nil, serialize_context: new_serialize_context, lock_owner: nil)
    associated_views = nil
    pre_rendered = owner_viewmodel.transaction do
      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, lock: lock_owner)
      ViewModel::Callbacks.wrap_serialize(owner_view, context: serialize_context) do
        # Association manipulation methods construct child contexts internally
        associated_views = owner_view.load_associated(association_name, scope: scope, serialize_context: serialize_context)

        associated_views = yield(associated_views) if block_given?

        child_context = owner_view.context_for_child(association_name, context: serialize_context)
        prerender_viewmodel(associated_views, serialize_context: child_context)
      end
    end
    render_json_string(pre_rendered)
    associated_views
  end

  def write_association(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context, lock_owner: nil)
    association_view = nil
    pre_rendered = owner_viewmodel.transaction do
      update_hash, refs = parse_viewmodel_updates

      owner_view = owner_viewmodel.find(owner_viewmodel_id, eager_include: false, lock: lock_owner)

      association_view = owner_view.replace_associated(association_name, update_hash,
                                                       references: refs,
                                                       deserialize_context: deserialize_context)

      ViewModel::Callbacks.wrap_serialize(owner_view, context: serialize_context) do
        child_context = owner_view.context_for_child(association_name, context: serialize_context)
        ViewModel.preload_for_serialization(association_view)
        association_view = yield(association_view) if block_given?
        prerender_viewmodel(association_view, serialize_context: child_context)
      end
    end
    render_json_string(pre_rendered)
    association_view
  end

  def destroy_association(collection, serialize_context: new_serialize_context, deserialize_context: new_deserialize_context, lock_owner: nil)
    if lock_owner
      owner_viewmodel.find(owner_viewmodel_id, eager_include: false, lock: lock_owner)
    end

    empty_update = collection ? [] : nil
    owner_viewmodel.deserialize_from_view(owner_update_hash(empty_update),
                                          deserialize_context: deserialize_context)
    render_viewmodel(empty_update, serialize_context: serialize_context)
  end

  def association_data
    owner_viewmodel._association_data(association_name)
  end

  def owner_update_hash(update)
    {
      ViewModel::ID_ATTRIBUTE   => owner_viewmodel_id,
      ViewModel::TYPE_ATTRIBUTE => owner_viewmodel.view_name,
      association_name.to_s     => update,
    }
  end

  def owner_viewmodel_id(required: true)
    id_param_name = owner_viewmodel.view_name.underscore + '_id'
    default = required ? {} : { default: nil }
    parse_param(id_param_name, **default)
  end

  def owner_viewmodel_class_for_name(name)
    ViewModel::Registry.for_view_name(name)
  end

  def owner_viewmodel
    name = params.fetch(:owner_viewmodel) { raise ArgumentError.new("No owner viewmodel present") }
    owner_viewmodel_class_for_name(name.to_s.camelize)
  end

  def association_name
    params.fetch(:association_name) { raise ArgumentError.new('No association name from routes') }
  end
end
