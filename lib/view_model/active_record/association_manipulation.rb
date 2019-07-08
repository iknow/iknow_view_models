# frozen_string_literal: true

# Mix-in for VM::ActiveRecord providing direct manipulation of
# directly-associated entities. Avoids loading entire collections.
module ViewModel::ActiveRecord::AssociationManipulation
  def load_associated(association_name, scope: nil, eager_include: true, serialize_context: self.class.new_serialize_context)
    association_data = self.class._association_data(association_name)
    direct_reflection = association_data.direct_reflection

    association = self.model.association(direct_reflection.name)
    association_scope = association.scope

    if association_data.through?
      raise ArgumentError.new("Polymorphic through relationships not supported yet") if association_data.polymorphic?
      associated_viewmodel = association_data.viewmodel_class
      direct_viewmodel     = association_data.direct_viewmodel
    else
      associated_viewmodel = association.klass.try { |k| association_data.viewmodel_class_for_model!(k) }
      direct_viewmodel     = associated_viewmodel
    end

    if direct_viewmodel._list_member?
      association_scope = association_scope.order(direct_viewmodel._list_attribute_name)
    end

    if association_data.through?
      association_scope = associated_viewmodel.model_class
                            .joins(association_data.indirect_reflection.inverse_of.name)
                            .merge(association_scope)
    end

    association_scope = association_scope.merge(scope) if scope

    vms = association_scope.map { |model| associated_viewmodel.new(model) }

    if eager_include
      child_context = self.context_for_child(association_name, context: serialize_context)
      ViewModel.preload_for_serialization(vms, serialize_context: child_context)
    end

    if association_data.collection?
      vms
    else
      if vms.size > 1
        raise ViewModel::DeserializationError::Internal.new("Internal error: encountered multiple records for single association #{association_name}", self.blame_reference)
      end
      vms.first
    end
  end

  # Replace the current member(s) of an association with the provided hash(es).
  def replace_associated(association_name, update_hash, references: {}, deserialize_context: self.class.new_deserialize_context)
    association_data = self.class._association_data(association_name)

    unless association_data.external?
      raise ViewModel::DeserializationError::InternalAssociationWrite.new(association_name, self.to_reference)
    end

    if association_data.referenced?
      is_fupdate =
        association_data.collection? &&
        update_hash.is_a?(Hash) &&
        update_hash[ViewModel::ActiveRecord::TYPE_ATTRIBUTE] == ViewModel::ActiveRecord::FUNCTIONAL_UPDATE_TYPE

      if is_fupdate
        update_hash[ViewModel::ActiveRecord::ACTIONS_ATTRIBUTE].each_with_index do |action, i|
          action_type_name = action[ViewModel::ActiveRecord::TYPE_ATTRIBUTE]
          if action_type_name == ViewModel::ActiveRecord::FunctionalUpdate::Remove::NAME
            # Remove actions are always type/id refs; others need to be translated to proper refs
            next
          end

          association_references = convert_updates_to_references(
            action[ViewModel::ActiveRecord::VALUES_ATTRIBUTE],
            key: "#{action_type_name}_#{i}")
          references.merge!(association_references)
          action[ViewModel::ActiveRecord::VALUES_ATTRIBUTE] =
            association_references.each_key.map { |ref| { ViewModel::REFERENCE_ATTRIBUTE => ref } }
        end
      else
        update_hash = ViewModel::Utils.wrap_one_or_many(update_hash) do |sh|
          association_references = convert_updates_to_references(sh, key: 'replace')
          references.merge!(association_references)
          association_references.each_key.map { |ref| { ViewModel::REFERENCE_ATTRIBUTE => ref } }
        end
      end
    end

    root_update_hash = {
      ViewModel::ID_ATTRIBUTE   => self.id,
      ViewModel::TYPE_ATTRIBUTE => self.class.view_name,
      association_name.to_s     => update_hash,
    }

    root_update_viewmodel = self.class.deserialize_from_view(root_update_hash, references: references, deserialize_context: deserialize_context)

    root_update_viewmodel._read_association(association_name)
  end

  # Create or update members of a associated collection. For an ordered
  # collection, the items are inserted either before `before`, after `after`, or
  # at the end.
  def append_associated(association_name, subtree_hash_or_hashes, references: {}, before: nil, after: nil, deserialize_context: self.class.new_deserialize_context)
    if self.changes.changed?
      raise ArgumentError.new('Invalid call to append_associated on viewmodel with pending changes')
    end

    association_data = self.class._association_data(association_name)
    direct_reflection = association_data.direct_reflection
    raise ArgumentError.new("Cannot append to single association '#{association_name}'") unless association_data.collection?

    unless association_data.external?
      raise ViewModel::DeserializationError::InternalAssociationWrite.new(association_name, self.to_reference)
    end

    ViewModel::Utils.wrap_one_or_many(subtree_hash_or_hashes) do |subtree_hashes|
      model_class.transaction do
        ViewModel::Callbacks.wrap_deserialize(self, deserialize_context: deserialize_context) do |hook_control|
          association_changed!(association_name)
          deserialize_context.run_callback(ViewModel::Callbacks::Hook::BeforeValidate, self)

          if association_data.through?
            raise ArgumentError.new("Polymorphic through relationships not supported yet") if association_data.polymorphic?

            direct_viewmodel_class = association_data.direct_viewmodel
            root_update_data, referenced_update_data = construct_indirect_append_updates(association_data, subtree_hashes, references)
          else
            direct_viewmodel_class = association_data.viewmodel_class
            root_update_data, referenced_update_data = construct_direct_append_updates(association_data, subtree_hashes, references)
          end

          update_context = ViewModel::ActiveRecord::UpdateContext.build!(root_update_data, referenced_update_data, root_type: direct_viewmodel_class)

          # Set new parent
          new_parent = ViewModel::ActiveRecord::UpdateOperation::ParentData.new(direct_reflection.inverse_of, self)
          update_context.root_updates.each { |update| update.reparent_to = new_parent }

          # Set place in list.
          if direct_viewmodel_class._list_member?
            new_positions = select_append_positions(association_data,
                                                    direct_viewmodel_class._list_attribute_name,
                                                    update_context.root_updates.count,
                                                    before: before, after: after)

            update_context.root_updates.zip(new_positions).each do |update, new_pos|
              update.reposition_to = new_pos
            end
          end

          # Because append_associated can take from other parents, edit-check previous parents (other than this model)
          unless association_data.through?
            inverse_assoc_name = direct_reflection.inverse_of.name

            previous_parent_ids = Set.new
            update_context.root_updates.each do |update|
              update_model    = update.viewmodel.model
              parent_model_id = update_model.read_attribute(update_model
                                                              .association(inverse_assoc_name)
                                                              .reflection.foreign_key)

              if parent_model_id && parent_model_id != self.id
                previous_parent_ids << parent_model_id
              end
            end

            if previous_parent_ids.present?
              previous_parents = self.class.find(previous_parent_ids.to_a, eager_include: false)

              previous_parents.each do |parent_view|
                ViewModel::Callbacks.wrap_deserialize(parent_view, deserialize_context: deserialize_context) do |pp_hook_control|
                  changes = ViewModel::Changes.new(changed_associations: [association_name])
                  deserialize_context.run_callback(ViewModel::Callbacks::Hook::OnChange, parent_view, changes: changes)
                  pp_hook_control.record_changes(changes)
                end
              end
            end
          end

          child_context = self.context_for_child(association_name, context: deserialize_context)
          updated_viewmodels = update_context.run!(deserialize_context: child_context)

          # Propagate changes and finalize the parent
          updated_viewmodels.each do |child|
            child_changes = child.previous_changes

            if association_data.nested?
              nested_children_changed!     if child_changes.changed_nested_tree?
              referenced_children_changed! if child_changes.changed_referenced_children?
            elsif association_data.owned?
              referenced_children_changed! if child_changes.changed_owned_tree?
            end
          end

          final_changes = self.clear_changes!

          if association_data.through?
            updated_viewmodels.map! do |direct_vm|
              direct_vm._read_association(association_data.indirect_reflection.name)
            end
          end

          # Could happen if hooks attempted to change the parent, which aren't
          # valid since we're only editing children here.
          unless final_changes.contained_to?(associations: [association_name.to_s])
            raise ViewModel::DeserializationError::InvalidParentEdit.new(final_changes, blame_reference)
          end

          deserialize_context.run_callback(ViewModel::Callbacks::Hook::OnChange, self, changes: final_changes)
          hook_control.record_changes(final_changes)

          updated_viewmodels
        end
      end
    end
  end

  # Removes the association between the models represented by this viewmodel and
  # the provided associated viewmodel. The associated model will be
  # garbage-collected if the assocation is specified with `dependent: :destroy`
  # or `:delete_all`
  def delete_associated(association_name, associated_id, type: nil, deserialize_context: self.class.new_deserialize_context)
    if self.changes.changed?
      raise ArgumentError.new('Invalid call to delete_associated on viewmodel with pending changes')
    end

    association_data = self.class._association_data(association_name)
    direct_reflection = association_data.direct_reflection

    unless association_data.external?
      raise ViewModel::DeserializationError::InternalAssociationWrite.new(association_name, self.to_reference)
    end

    unless association_data.collection?
      raise ArgumentError.new("Cannot remove element from single association '#{association_name}'")
    end

    check_association_type!(association_data, type)
    target_ref = ViewModel::Reference.new(type || association_data.viewmodel_class, associated_id)

    model_class.transaction do
      ViewModel::Callbacks.wrap_deserialize(self, deserialize_context: deserialize_context) do |hook_control|
        association_changed!(association_name)
        deserialize_context.run_callback(ViewModel::Callbacks::Hook::BeforeValidate, self)

        association = self.model.association(direct_reflection.name)
        association_scope = association.scope

        if association_data.through?
          raise ArgumentError.new('Polymorphic through relationships not supported yet') if association_data.polymorphic?

          direct_viewmodel = association_data.direct_viewmodel
          association_scope = association_scope.where(association_data.indirect_reflection.foreign_key => associated_id)
        else
          # viewmodel type for current association: nil in case of empty polymorphic association
          direct_viewmodel = association.klass.try { |k| association_data.viewmodel_class_for_model!(k) }

          if association_data.pointer_location == :local
            # If we hold the pointer, we can immediately check if the type and id match.
            if target_ref != ViewModel::Reference.new(direct_viewmodel, model.read_attribute(direct_reflection.foreign_key))
              raise ViewModel::DeserializationError::AssociatedNotFound.new(association_name.to_s, target_ref, blame_reference)
            end
          else
            # otherwise add the target constraint to the association scope
            association_scope = association_scope.where(id: associated_id)
          end
        end

        models = association_scope.to_a

        if models.blank?
          raise ViewModel::DeserializationError::AssociatedNotFound.new(association_name.to_s, target_ref, blame_reference)
        elsif models.size > 1
          raise ViewModel::DeserializationError::Internal.new(
                  "Internal error: encountered multiple records for #{target_ref} in association #{association_name}",
                  blame_reference)
        end

        child_context = self.context_for_child(association_name, context: deserialize_context)
        child_vm = direct_viewmodel.new(models.first)

        ViewModel::Callbacks.wrap_deserialize(child_vm, deserialize_context: child_context) do |child_hook_control|
          changes = ViewModel::Changes.new(deleted: true)
          child_context.run_callback(ViewModel::Callbacks::Hook::OnChange, child_vm, changes: changes)
          child_hook_control.record_changes(changes)

          association.delete(child_vm.model)
        end

        if association_data.nested?
          nested_children_changed!
        elsif association_data.owned?
          referenced_children_changed!
        end

        final_changes = self.clear_changes!

        unless final_changes.contained_to?(associations: [association_name.to_s])
          raise ViewModel::DeserializationError::InvalidParentEdit.new(final_changes, blame_reference)
        end

        deserialize_context.run_callback(ViewModel::Callbacks::Hook::OnChange, self, changes: final_changes)
        hook_control.record_changes(final_changes)

        child_vm
      end
    end
  end

  private

  def construct_direct_append_updates(_association_data, subtree_hashes, references)
    ViewModel::ActiveRecord::UpdateData.parse_hashes(subtree_hashes, references)
  end

  def construct_indirect_append_updates(association_data, subtree_hashes, references)
    indirect_reflection = association_data.indirect_reflection
    direct_viewmodel_class = association_data.direct_viewmodel

    # Construct updates for the provided indirectly-associated hashes
    indirect_update_data, referenced_update_data = ViewModel::ActiveRecord::UpdateData.parse_hashes(subtree_hashes, references)

    # Convert associated update data to references
    indirect_references = convert_updates_to_references(indirect_update_data, key: 'indirect_append')
    referenced_update_data.merge!(indirect_references)

    # Find any existing models for the direct association: need to re-use any
    # existing join-table entries, to maintain single membership of each
    # associate.
    # TODO: this won't handle polymorphic associations! In the case of polymorphism,
    #       need to join on (type, id) pairs instead.
    if association_data.polymorphic?
      raise ArgumentError.new("Internal error: append_association is not yet supported for polymorphic indirect associations")
    end

    existing_indirect_associates = indirect_update_data.map { |upd| upd.id unless upd.new? }.compact

    direct_association_scope = model.association(association_data.direct_reflection.name).scope

    existing_direct_ids = direct_association_scope
                            .where(indirect_reflection.foreign_key => existing_indirect_associates)
                            .pluck(indirect_reflection.foreign_key, :id)
                            .to_h

    direct_update_data = indirect_references.map do |ref_name, update|
      existing_id = existing_direct_ids[update.id] unless update.new?

      metadata = ViewModel::Metadata.new(existing_id,
                                         direct_viewmodel_class.view_name,
                                         direct_viewmodel_class.schema_version,
                                         existing_id.nil?)

      ViewModel::ActiveRecord::UpdateData.new(
        direct_viewmodel_class,
        metadata,
        { indirect_reflection.name.to_s => { ViewModel::REFERENCE_ATTRIBUTE => ref_name }},
        [ref_name])
    end

    return direct_update_data, referenced_update_data
  end

  def convert_updates_to_references(indirect_update_data, key:)
    indirect_update_data.each.with_index.with_object({}) do |(update, i), indirect_references|
      indirect_references["__#{key}_ref_#{i}"] = update
    end
  end

  # TODO: this functionality could reasonably be extracted into `acts_as_manual_list`.
  def select_append_positions(association_data, position_attr, append_count, before:, after:)
    direct_reflection = association_data.direct_reflection
    association_scope = model.association(direct_reflection.name).scope

    search_key =
      if association_data.through?
        association_data.indirect_reflection.foreign_key
      else
        :id
      end

    if (relative_ref = (before || after))
      relative_target = association_scope.where(search_key => relative_ref.model_id).select(:position)
      if before
        end_pos, start_pos = association_scope.where("#{position_attr} <= (?)", relative_target).order("#{position_attr} DESC").limit(2).pluck(:position)
      else
        start_pos, end_pos = association_scope.where("#{position_attr} >= (?)", relative_target).order("#{position_attr} ASC").limit(2).pluck(:position)
      end

      if start_pos.nil? && end_pos.nil?
        # Attempted to insert relative to ref that's not in the association
        raise ViewModel::DeserializationError::AssociatedNotFound.new(association_data.association_name.to_s,
                                                                      relative_ref,
                                                                      blame_reference)
      end
    else
      start_pos = association_scope.maximum(position_attr)
      end_pos   = nil
    end

    ActsAsManualList.select_positions(start_pos, end_pos, append_count)
  end

  def check_association_type!(association_data, type)
    if type && !association_data.accepts?(type)
      raise ViewModel::SerializationError.new(
              "Type error: association '#{direct_reflection.name}' can't refer to viewmodel #{type.view_name}")
    elsif association_data.polymorphic? && !type
      raise ViewModel::SerializationError.new(
              "Need to specify target viewmodel type for polymorphic association '#{direct_reflection.name}'")
    end
  end
end
