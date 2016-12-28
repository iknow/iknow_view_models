# Mix-in for VM::ActiveRecord providing direct manipulation of
# directly-associated entities.
class ViewModel::ActiveRecord
module AssociationManipulation

  def load_associated(association_name)
    self.public_send(association_name)
  end

  def find_associated(association_name, id, eager_include: true, serialize_context: self.class.new_serialize_context)
    association_data = self.class._association_data(association_name)
    associated_viewmodel = association_data.viewmodel_class
    association_scope = self.model.association(association_name).association_scope
    associated_viewmodel.find(id, scope: association_scope, eager_include: eager_include, serialize_context: serialize_context)
  end

  # Create or update a single member of an associated collection. For an ordered
  # collection, the new item is added at the end appended.
  def append_associated(association_name, subtree_hashes, references: {}, deserialize_context: self.class.new_deserialize_context)
    return_array = subtree_hashes.is_a?(Array)
    subtree_hashes = Array.wrap(subtree_hashes)

    model_class.transaction do
      editable!(deserialize_context: deserialize_context, changed_associations: [association_name])

      association_data = self.class._association_data(association_name)

      raise ArgumentError.new("Cannot append to single association '#{association_name}'") unless association_data.collection?

      associated_viewmodel_class = association_data.viewmodel_class

      # Construct an update operation tree for the provided child hashes
      viewmodel_class = association_data.viewmodel_class

      root_update_data, referenced_update_data = UpdateData.parse_hashes(subtree_hashes, references)
      update_context = UpdateContext.build!(root_update_data, referenced_update_data, root_type: viewmodel_class)

      # Provide information about what was updated
      deserialize_context.updated_associations = root_update_data
                                                   .map { |upd| upd.updated_associations }
                                                   .inject({}) { |acc, assocs| acc.deep_merge(assocs) }

      # Set new parent
      new_parent = ViewModel::ActiveRecord::UpdateOperation::ParentData.new(association_data.direct_reflection.inverse_of, self)
      update_context.root_updates.each { |update| update.reparent_to = new_parent }

      # Set place in list
      if associated_viewmodel_class._list_member?
        last_position = model.association(association_name).scope.maximum(associated_viewmodel_class._list_attribute_name) || 0
        base_position = last_position + 1.0
        update_context.root_updates.each_with_index { |update, index| update.reposition_to = base_position + index }
      end

      updated_viewmodels = update_context.run!(deserialize_context: deserialize_context)

      if return_array
        updated_viewmodels
      else
        updated_viewmodels.first
      end
    end
  end

  # Removes the association between the models represented by this viewmodel and
  # the provided associated viewmodel. The associated model will be
  # garbage-collected if the assocation is specified with `dependent: :destroy`
  # or `:delete_all`
  def delete_associated(association_name, associated, deserialize_context: self.class.new_deserialize_context)
    model_class.transaction do
      editable!(deserialize_context: deserialize_context, changed_associations: [association_name])

      association_data = self.class._association_data(association_name)

      unless association_data.collection?
        raise ArgumentError.new("Cannot remove element from single association '#{association_name}'")
      end

      association = model.association(association_name)
      association.delete(associated.model)
    end
  end
end
end
