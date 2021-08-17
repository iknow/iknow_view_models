# frozen_string_literal: true

# Mix-in for VM::ActiveRecord providing direct manipulation of
# directly-associated entities. Avoids loading entire collections.
module ViewModel::ActiveRecord::AssociationManipulation
  extend ActiveSupport::Concern

  def load_associated(association_name, scope: nil, eager_include: true, serialize_context: self.class.new_serialize_context)
    association_data = self.class._association_data(association_name)
    direct_reflection = association_data.direct_reflection

    association = self.model.association(direct_reflection.name)
    association_scope = association.scope

    if association_data.through?
      raise ArgumentError.new('Polymorphic through relationships not supported yet') if association_data.polymorphic?

      associated_viewmodel = association_data.viewmodel_class
      direct_viewmodel     = association_data.direct_viewmodel
    else
      raise ArgumentError.new('Polymorphic STI relationships not supported yet') if association_data.polymorphic?

      associated_viewmodel = association.klass.try { |k| association_data.viewmodel_class_for_model!(k) }
      direct_viewmodel     = associated_viewmodel
    end

    if association_data.ordered?
      association_scope = association_scope.order(direct_viewmodel._list_attribute_name)
    end

    if association_data.through?
      association_scope = associated_viewmodel.model_class
                            .joins(association_data.indirect_reflection.inverse_of.name)
                            .merge(association_scope)
    end

    association_scope = association_scope.merge(scope) if scope

    vms = association_scope.map { |model| associated_viewmodel.new(model) }

    ViewModel.preload_for_serialization(vms) if eager_include

    if association_data.collection?
      vms
    else
      if vms.size > 1
        raise ViewModel::DeserializationError::Internal.new("Internal error: encountered multiple records for single association #{association_name}", self.blame_reference)
      end

      vms.first
    end
  end

  # Replace the current member(s) of an association with the provided
  # hash(es).  Only mentioned member(s) will be returned.
  #
  # This interface deals with associations directly where reasonable,
  # with the notable exception of referenced+shared associations. That
  # is to say, that owned associations should be presented in the form
  # of direct update hashes, regardless of their
  # referencing. Reference and shared associations are excluded to
  # ensure that the update hash for a shared entity is unique, and
  # that edits may only be specified once.
  def replace_associated(association_name, update_hash, references: {}, deserialize_context: self.class.new_deserialize_context)
    _updated_parent, changed_children =
      self.class.replace_associated_bulk(
        association_name,
        { self.id => update_hash },
        references: references,
        deserialize_context: deserialize_context
      ).first

    changed_children
  end

  class_methods do
    # Replace the current member(s) of an association with the provided
    # hash(es) for many viewmodels.  Only mentioned members will be returned.
    #
    # This is an interim implementation that requires loading the contents of
    # all collections into memory and filtering for the mentioned entities,
    # even for functional updates.  This is in contrast to append_associated,
    # which only operates on the new entities.
    def replace_associated_bulk(association_name, updates_by_parent_id, references:, deserialize_context: self.class.new_deserialize_context)
      association_data = _association_data(association_name)

      touched_ids = updates_by_parent_id.each_with_object({}) do |(parent_id, update_hash), acc|
        acc[parent_id] =
          mentioned_children(
            update_hash,
            references:       references,
            association_data: association_data,
          ).to_set
      end

      root_update_hashes = updates_by_parent_id.map do |parent_id, update_hash|
        {
          ViewModel::ID_ATTRIBUTE   => parent_id,
          ViewModel::TYPE_ATTRIBUTE => view_name,
          association_name.to_s     => update_hash,
        }
      end

      root_update_viewmodels = deserialize_from_view(
        root_update_hashes, references: references, deserialize_context: deserialize_context)

      root_update_viewmodels.each_with_object({}) do |updated, acc|
        acc[updated] = updated._read_association_touched(association_name, touched_ids: touched_ids.fetch(updated.id))
      end
    end
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

    ViewModel::Utils.wrap_one_or_many(subtree_hash_or_hashes) do |subtree_hashes|
      model_class.transaction do
        ViewModel::Callbacks.wrap_deserialize(self, deserialize_context: deserialize_context) do |hook_control|
          association_changed!(association_name)
          deserialize_context.run_callback(ViewModel::Callbacks::Hook::BeforeValidate, self)

          if association_data.through?
            raise ArgumentError.new('Polymorphic through relationships not supported yet') if association_data.polymorphic?

            direct_viewmodel_class = association_data.direct_viewmodel
            root_update_data, referenced_update_data = construct_indirect_append_updates(association_data, subtree_hashes, references)
          else
            raise ArgumentError.new('Polymorphic STI relationships not supported yet') if association_data.polymorphic?

            direct_viewmodel_class = association_data.viewmodel_class
            root_update_data, referenced_update_data = construct_direct_append_updates(association_data, subtree_hashes, references)
          end

          update_context = ViewModel::ActiveRecord::UpdateContext.build!(root_update_data, referenced_update_data, root_type: direct_viewmodel_class)

          # Set new parent
          new_parent = ViewModel::ActiveRecord::UpdateOperation::ParentData.new(direct_reflection.inverse_of, self)
          update_context.root_updates.each { |update| update.reparent_to = new_parent }

          # Set place in list.
          if association_data.ordered?
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
          raise ArgumentError.new('Polymorphic STI relationships not supported yet') if association_data.polymorphic?

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
    indirect_references =
      self.class.convert_updates_to_references(
        indirect_update_data, key: 'indirect_append')

    referenced_update_data.merge!(indirect_references)

    # Find any existing models for the direct association: need to re-use any
    # existing join-table entries, to maintain single membership of each
    # associate.
    # TODO: this won't handle polymorphic associations! In the case of polymorphism,
    #       need to join on (type, id) pairs instead.
    if association_data.polymorphic?
      raise ArgumentError.new('Internal error: append_association is not yet supported for polymorphic indirect associations')
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
        { indirect_reflection.name.to_s => { ViewModel::REFERENCE_ATTRIBUTE => ref_name } },
        [ref_name])
    end

    return direct_update_data, referenced_update_data
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
              "Type error: association '#{association_data.association_name}' can't refer to viewmodel #{type.view_name}")
    elsif association_data.polymorphic? && !type
      raise ViewModel::SerializationError.new(
              "Need to specify target viewmodel type for polymorphic association '#{association_data.association_name}'")
    end
  end

  class_methods do
    def convert_updates_to_references(indirect_update_data, key:)
      indirect_update_data.each.with_index.with_object({}) do |(update, i), indirect_references|
        indirect_references["__#{key}_ref_#{i}"] = update
      end
    end

    def add_reference_indirection(update_hash, association_data:, references:, key:)
      raise ArgumentError.new('Not a referenced association') unless association_data.referenced?

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
            key: "#{key}_#{action_type_name}_#{i}")
          references.merge!(association_references)
          action[ViewModel::ActiveRecord::VALUES_ATTRIBUTE] =
            association_references.each_key.map { |ref| { ViewModel::REFERENCE_ATTRIBUTE => ref } }
        end

        update_hash
      else
        ViewModel::Utils.wrap_one_or_many(update_hash) do |sh|
          association_references = convert_updates_to_references(sh, key: "#{key}_replace")
          references.merge!(association_references)
          association_references.each_key.map { |ref| { ViewModel::REFERENCE_ATTRIBUTE => ref } }
        end
      end
    end

    # Traverses literals and fupdates to return referenced children.
    #
    # Runs before the main parser, so must be defensive
    def each_child_hash(assoc_update, association_data:)
      return enum_for(__method__, assoc_update, association_data: association_data) unless block_given?

      is_fupdate =
        association_data.collection? &&
          assoc_update.is_a?(Hash) &&
          assoc_update[ViewModel::ActiveRecord::TYPE_ATTRIBUTE] == ViewModel::ActiveRecord::FUNCTIONAL_UPDATE_TYPE

      if is_fupdate
        assoc_update.fetch(ViewModel::ActiveRecord::ACTIONS_ATTRIBUTE).each do |action|
          action_type_name = action[ViewModel::ActiveRecord::TYPE_ATTRIBUTE]
          if action_type_name.nil?
            raise ViewModel::DeserializationError::InvalidSyntax.new(
              "Functional update missing '#{ViewModel::ActiveRecord::TYPE_ATTRIBUTE}'"
            )
          end

          if action_type_name == ViewModel::ActiveRecord::FunctionalUpdate::Remove::NAME
            # Remove actions are not considered children of the action.
            next
          end

          values = action.fetch(ViewModel::ActiveRecord::VALUES_ATTRIBUTE) {
            raise ViewModel::DeserializationError::InvalidSyntax.new(
              "Functional update missing '#{ViewModel::ActiveRecord::VALUES_ATTRIBUTE}'"
            )
          }
          values.each { |x| yield x }
        end
      else
        ViewModel::Utils.wrap_one_or_many(assoc_update) do |assoc_updates|
          assoc_updates.each { |u| yield u }
        end
      end
    end

    # Collects the ids of children that are mentioned in the update data.
    #
    # Runs before the main parser, so must be defensive.
    def mentioned_children(assoc_update, references:, association_data:)
      return enum_for(__method__, assoc_update, references: references, association_data: association_data) unless block_given?

      each_child_hash(assoc_update, association_data: association_data).each do |child_hash|
        unless child_hash.is_a?(Hash)
          raise ViewModel::DeserializationError::InvalidSyntax.new(
            "Expected update hash, received: #{child_hash}"
          )
        end

        if association_data.referenced?
          ref_handle = child_hash.fetch(ViewModel::REFERENCE_ATTRIBUTE) {
            raise ViewModel::DeserializationError::InvalidSyntax.new(
              "Reference hash missing '#{ViewModel::REFERENCE_ATTRIBUTE}'"
            )
          }

          ref_update_hash = references.fetch(ref_handle) {
            raise ViewModel::DeserializationError::InvalidSyntax.new(
              "Reference '#{ref_handle}' does not exist in references"
            )
          }

          unless ref_update_hash.is_a?(Hash)
            raise ViewModel::DeserializationError::InvalidSyntax.new(
              "Expected update hash, received: #{child_hash}"
            )
          end

          if (id = ref_update_hash[ViewModel::ID_ATTRIBUTE])
            yield id
          end
        else
          if (id = child_hash[ViewModel::ID_ATTRIBUTE])
            yield id
          end
        end
      end
    end
  end
end
