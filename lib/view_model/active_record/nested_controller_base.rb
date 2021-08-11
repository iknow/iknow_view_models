# frozen_string_literal: true

require 'view_model/active_record/controller_base'

# Controller mixin defining machinery for accessing viewmodels nested under a
# parent. Used by Singular- and CollectionNestedControllers
module ViewModel::ActiveRecord::NestedControllerBase
  extend ActiveSupport::Concern

  class ParentProxyModel < ViewModel
    # Prevent this from appearing in hooks
    self.synthetic = true

    attr_reader :parent, :association_data, :changed_children

    def initialize(parent, association_data, changed_children)
      @parent = parent
      @association_data = association_data
      @changed_children = changed_children
    end

    def serialize(json, serialize_context:)
      ViewModel::Callbacks.wrap_serialize(parent, context: serialize_context) do
        child_context = parent.context_for_child(association_data.association_name, context: serialize_context)

        json.set!(ViewModel::ID_ATTRIBUTE, parent.id)
        json.set!(ViewModel::BULK_UPDATE_ATTRIBUTE) do
          if association_data.referenced? && !association_data.owned?
            if association_data.collection?
              json.array!(changed_children) do |child|
                ViewModel.serialize_as_reference(child, json, serialize_context: child_context)
              end
            else
              ViewModel.serialize_as_reference(changed_children, json, serialize_context: child_context)
            end
          else
            ViewModel.serialize(changed_children, json, serialize_context: child_context)
          end
        end
      end
    end
  end

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

  # This method always takes direct update hashes, and returns
  # viewmodels directly.
  #
  # There's no multi membership, so when viewing the children of a
  # single parent each child can only appear once. This means it's
  # safe to use update hashes directly.
  def write_association(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context, lock_owner: nil)
    association_view = nil
    pre_rendered = owner_viewmodel.transaction do
      update_hash, refs = parse_viewmodel_updates

      association_data = owner_viewmodel._association_data(association_name)
      if association_data.referenced?
        update_hash =
          ViewModel::ActiveRecord.add_reference_indirection(
            update_hash,
            association_data: association_data,
            references:       refs,
            key:              'write-association',
          )
      end

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

  # This method takes direct update hashes for owned associations, and
  # reference hashes for shared associations. The return value matches
  # the input structure.
  #
  # If an association is referenced and owned, each child may only
  # appear once so each is guaranteed to have a unique update
  # hash. This means it's only safe to use update hashes directly in
  # this case.
  def write_association_bulk(serialize_context: new_serialize_context, deserialize_context: new_deserialize_context, lock_owner: nil)
    updated_by_parent_viewmodel = nil

    association_data = owner_viewmodel._association_data(association_name)

    pre_rendered = owner_viewmodel.transaction do
      updates_by_parent_id, references = parse_bulk_update

      if association_data.referenced? && association_data.owned?
        updates_by_parent_id.transform_values!.with_index do |update_hash, index|
          ViewModel::ActiveRecord.add_reference_indirection(
            update_hash,
            association_data: association_data,
            references:       references,
            key:              "write-association-bulk-#{index}",
          )
        end
      end

      updated_by_parent_viewmodel =
        owner_viewmodel.replace_associated_bulk(
          association_name,
          updates_by_parent_id,
          references:          references,
          deserialize_context: deserialize_context,
        )

      views = updated_by_parent_viewmodel.flat_map { |_parent_viewmodel, updated_views| Array.wrap(updated_views) }

      ViewModel.preload_for_serialization(views)

      updated_by_parent_viewmodel = yield(updated_by_parent_viewmodel) if block_given?

      return_updates = updated_by_parent_viewmodel.map do |owner_view, updated_views|
        ParentProxyModel.new(owner_view, association_data, updated_views)
      end

      return_structure = {
        ViewModel::TYPE_ATTRIBUTE         => ViewModel::BULK_UPDATE_TYPE,
        ViewModel::BULK_UPDATES_ATTRIBUTE => return_updates,
      }

      prerender_viewmodel(return_structure, serialize_context: serialize_context)
    end

    render_json_string(pre_rendered)
    updated_by_parent_viewmodel
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
