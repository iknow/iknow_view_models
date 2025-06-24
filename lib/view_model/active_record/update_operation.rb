# frozen_string_literal: true

require 'renum'

# Partially parsed tree of user-specified update hashes, created during deserialization.
class ViewModel::ActiveRecord
  using ViewModel::Utils::Collections
  include ViewModel::ErrorWrapping

  class UpdateOperation
    # inverse association and record to update a change in parent from a child
    ParentData = Struct.new(:association_reflection, :viewmodel)

    enum :RunState, [:Pending, :Running, :Run]

    attr_accessor :viewmodel,
                  :update_data,
                  :association_updates, # AssociationData => UpdateOperation(s)
                  :reparent_to, # If node needs to update its pointer to a new parent, ParentData for the parent
                  :reposition_to, # if this node participates in a list under its parent, what should its position be?
                  :released_children # Set of children that have been released

    delegate :attributes, to: :update_data

    def initialize(viewmodel, update_data, reparent_to: nil, reposition_to: nil)
      self.viewmodel           = viewmodel
      self.update_data         = update_data
      self.association_updates = {}
      self.reparent_to         = reparent_to
      self.reposition_to       = reposition_to
      self.released_children   = []

      @run_state = RunState::Pending
      @changed_associations = []
      @built = false
    end

    def viewmodel_reference
      unless viewmodel.model.new_record?
        viewmodel.to_reference
      end
    end

    def built?
      @built
    end

    def reference_only?
      update_data.reference_only? && reparent_to.nil? && reposition_to.nil?
    end

    # Evaluate a built update tree, applying and saving changes to the models.
    def run!(deserialize_context:)
      raise ViewModel::DeserializationError::Internal.new('Internal error: UpdateOperation run before build') unless built?

      case @run_state
      when RunState::Running
        raise ViewModel::DeserializationError::Internal.new('Internal error: Cycle found in running UpdateOperation')
      when RunState::Run
        return viewmodel
      end

      @run_state = RunState::Running

      model = viewmodel.model

      debug_name = "#{model.class.name}:#{model.id || '<new>'}"
      debug "-> #{debug_name}: Entering"

      model.class.transaction do
        # Run context and viewmodel hooks
        wrap_active_record_errors(self.blame_reference) do
          ViewModel::Callbacks.wrap_deserialize(viewmodel, deserialize_context: deserialize_context) do |hook_control|
            # update parent association
            if reparent_to.present?
              debug "-> #{debug_name}: Updating parent pointer to '#{reparent_to.viewmodel.class.view_name}:#{reparent_to.viewmodel.id}'"
              association = model.association(reparent_to.association_reflection.name)
              association.writer(reparent_to.viewmodel.model)
              debug "<- #{debug_name}: Updated parent pointer"
            end

            # update position
            if reposition_to.present?
              debug "-> #{debug_name}: Updating position to #{reposition_to}"
              viewmodel._list_attribute = reposition_to
            end

            # Visit attributes and associations as much as possible in the order
            # that they're declared in the view. We can visit attributes and
            # points-to associations before save, but points-from associations
            # must be visited after save.
            pre_save_members, post_save_members = viewmodel.class._members.values.partition do |member_data|
              !member_data.association? || member_data.pointer_location == :local
            end

            pre_save_members.each do |member_data|
              if member_data.association?
                next unless association_updates.include?(member_data)

                child_operation = association_updates[member_data]

                reflection = member_data.direct_reflection
                debug "-> #{debug_name}: Updating points-to association '#{reflection.name}'"

                association = model.association(reflection.name)
                new_target =
                  if child_operation
                    child_ctx = viewmodel.context_for_child(member_data.association_name, context: deserialize_context)
                    child_viewmodel = child_operation.run!(deserialize_context: child_ctx)
                    propagate_tree_changes(member_data, child_viewmodel.previous_changes)

                    child_viewmodel.model
                  end
                association.writer(new_target)
                debug "<- #{debug_name}: Updated points-to association '#{reflection.name}'"
              else
                attr_name = member_data.name
                next unless attributes.include?(attr_name)

                serialized_value = attributes[attr_name]
                # Note that the VM::AR deserialization tree asserts ownership over any
                # references it's provided, and so they're intentionally not passed on
                # to attribute deserialization for use by their `using:` viewmodels. A
                # (better?) alternative would be to provide them as reference-only
                # hashes, to indicate that no modification can be permitted.
                viewmodel.public_send("deserialize_#{attr_name}", serialized_value,
                                      references: {},
                                      deserialize_context: deserialize_context)
              end
            end

            # If a request makes no assertions about the model, we don't demand
            # that the current state of the model is valid. This permits making
            # edits to other models that refer to this model when this model is
            # invalid.
            unless reference_only? && !viewmodel.new_model?
              deserialize_context.run_callback(ViewModel::Callbacks::Hook::BeforeValidate, viewmodel)
              viewmodel.validate!
            end

            # Save if the model has been altered. Covers not only models with
            # view changes but also lock version assertions.
            if viewmodel.model.changed? || viewmodel.model.new_record?
              debug "-> #{debug_name}: Saving"
              model.save!
              debug "<- #{debug_name}: Saved"
            end

            # Update association cache of pointed-from associations after save: the
            # child update will have saved the pointer.
            post_save_members.each do |association_data|
              next unless association_updates.include?(association_data)

              child_operation = association_updates[association_data]
              reflection = association_data.direct_reflection

              debug "-> #{debug_name}: Updating pointed-to association '#{reflection.name}'"

              association = model.association(reflection.name)
              child_ctx = viewmodel.context_for_child(association_data.association_name, context: deserialize_context)

              new_target =
                if child_operation
                  ViewModel::Utils.map_one_or_many(child_operation) do |op|
                    child_viewmodel = op.run!(deserialize_context: child_ctx)
                    propagate_tree_changes(association_data, child_viewmodel.previous_changes)

                    child_viewmodel.model
                  end
                end

              association.target = new_target

              debug "<- #{debug_name}: Updated pointed-to association '#{reflection.name}'"
            end

            if self.released_children.present?
              # Released children that were not reclaimed by other parents during the
              # build phase will be deleted: check access control.
              debug "-> #{debug_name}: Checking released children permissions"
              self.released_children.reject(&:claimed?).each do |released_child|
                debug "-> #{debug_name}: Checking #{released_child.viewmodel.to_reference}"
                child_vm = released_child.viewmodel
                child_association_data = released_child.association_data
                child_ctx = viewmodel.context_for_child(child_association_data.association_name, context: deserialize_context)

                ViewModel::Callbacks.wrap_deserialize(child_vm, deserialize_context: child_ctx) do |child_hook_control|
                  changes = ViewModel::Changes.new(deleted: true)
                  child_ctx.run_callback(ViewModel::Callbacks::Hook::OnChange,
                                         child_vm,
                                         changes: changes)
                  child_hook_control.record_changes(changes)
                end

                if child_association_data.nested?
                  viewmodel.nested_children_changed!
                elsif child_association_data.owned?
                  viewmodel.referenced_children_changed!
                end
              end
              debug "<- #{debug_name}: Finished checking released children permissions"
            end

            final_changes = viewmodel.clear_changes!

            if final_changes.changed?
              # Now that the change has been fully attempted, call the OnChange
              # hook if local changes were made
              deserialize_context.run_callback(ViewModel::Callbacks::Hook::OnChange, viewmodel, changes: final_changes)
            end

            hook_control.record_changes(final_changes)
          end
        end
      end

      debug "<- #{debug_name}: Leaving"

      @run_state = RunState::Run
      viewmodel
    end

    def propagate_tree_changes(association_data, child_changes)
      if association_data.nested?
        viewmodel.nested_children_changed!     if child_changes.changed_nested_tree?
        viewmodel.referenced_children_changed! if child_changes.changed_referenced_children?
      elsif association_data.owned?
        viewmodel.referenced_children_changed! if child_changes.changed_owned_tree?
      end
    end

    # Recursively builds UpdateOperations for the associations in our UpdateData
    def build!(update_context)
      raise ViewModel::DeserializationError::Internal.new('Internal error: UpdateOperation cannot build a deferred update') if viewmodel.nil?
      return self if built?

      update_data.associations.each do |association_name, association_update_data|
        association_data = self.viewmodel.class._association_data(association_name)
        update =
          if association_data.collection?
            build_updates_for_collection_association(association_data, association_update_data, update_context)
          else
            build_update_for_single_association(association_data, association_update_data, update_context)
          end

        add_update(association_data, update)
      end

      update_data.referenced_associations.each do |association_name, reference_string|
        association_data = self.viewmodel.class._association_data(association_name)

        update =
          if association_data.through?
            build_updates_for_collection_referenced_association(association_data, reference_string, update_context)
          elsif association_data.collection?
            build_updates_for_collection_association(association_data, reference_string, update_context)
          else
            build_update_for_single_association(association_data, reference_string, update_context)
          end

        add_update(association_data, update)
      end

      @built = true
      self
    end

    def add_update(association_data, update)
      self.association_updates[association_data] = update
    end

    private

    # Resolve or construct viewmodels for incoming update data. Where a child
    # hash references an existing model not currently attached to this parent,
    # it must be found before recursing into that child. If the model is
    # available in released models we can take it and recurse, otherwise we must
    # return a ViewModel::Reference to be added to the worklist for deferred
    # resolution.
    def resolve_child_viewmodels(association_data, update_datas, previous_child_viewmodels, update_context)
      if self.viewmodel.respond_to?(:"resolve_#{association_data.direct_reflection.name}")
        return self.viewmodel.public_send(:"resolve_#{association_data.direct_reflection.name}", update_datas, previous_child_viewmodels)
      end

      previous_child_viewmodels = Array.wrap(previous_child_viewmodels)

      previous_by_key = previous_child_viewmodels.index_by do |vm|
        vm.to_reference
      end

      ViewModel::Utils.map_one_or_many(update_datas) do |update_data|
        child_viewmodel_class = update_data.viewmodel_class
        key = ViewModel::Reference.new(child_viewmodel_class, update_data.id)

        case
        when update_data.new?
          child_viewmodel_class.for_new_model(id: update_data.id)
        when update_data.child_update?
          if association_data.collection?
            raise ViewModel::DeserializationError::InvalidStructure.new(
                    'Cannot update existing children of a collection association without specified ids',
                    ViewModel::Reference.new(update_data.viewmodel_class, nil))
          end

          child = previous_child_viewmodels[0]

          if child.nil?
            unless update_data.auto_child_update?
              raise ViewModel::DeserializationError::PreviousChildNotFound.new(
                    association_data.association_name.to_s,
                    self.blame_reference)
            end

            child = child_viewmodel_class.for_new_model
          end

          child
        when existing_child = previous_by_key[key]
          existing_child
        when taken_child = update_context.try_take_released_viewmodel(key)
          taken_child
        else
          # Refers to child that hasn't yet been seen: create a deferred update.
          key
        end
      end
    end

    def resolve_referenced_viewmodels(association_data, update_datas, previous_child_viewmodels, update_context)
      previous_child_viewmodels = Array.wrap(previous_child_viewmodels).index_by(&:to_reference)

      ViewModel::Utils.map_one_or_many(update_datas) do |update_data|
        if update_data.is_a?(UpdateData)
          # Dummy child update data for an unmodified previous child of a
          # functional update; create it an empty update operation.
          viewmodel = previous_child_viewmodels.fetch(update_data.viewmodel_reference)
          update    = update_context.new_update(viewmodel, update_data)
          next [update, viewmodel]
        end

        reference_string = update_data
        child_update     = update_context.resolve_reference(reference_string, blame_reference)
        child_viewmodel  = child_update.viewmodel

        unless association_data.accepts?(child_viewmodel.class)
          raise ViewModel::DeserializationError::InvalidAssociationType.new(
                  association_data.association_name.to_s,
                  child_viewmodel.class.view_name,
                  blame_reference)
        end

        child_ref = child_viewmodel.to_reference

        # The case of two potential owners trying to claim a new referenced
        # child is covered by set_reference_update_parent.
        claimed = !association_data.owned? ||
                  child_update.update_data.new? ||
                  previous_child_viewmodels.has_key?(child_ref) ||
                  update_context.try_take_released_viewmodel(child_ref).present?

        if claimed
          [child_update, child_viewmodel]
        else
          # Return the reference to indicate a deferred update
          [child_update, child_ref]
        end
      end
    end

    def set_reference_update_parent(association_data, update, parent_data)
      if update.reparent_to
        # Another parent has already tried to take this (probably new)
        # owned referenced view. It can only be claimed by one of them.
        other_parent = update.reparent_to.viewmodel.to_reference
        raise ViewModel::DeserializationError::DuplicateOwner.new(
                association_data.association_name,
                [blame_reference, other_parent])
      end

      update.reparent_to = parent_data
    end

    def build_update_for_single_association(association_data, association_update_data, update_context)
      model = self.viewmodel.model

      previous_child_viewmodel = model.public_send(association_data.direct_reflection.name).try do |previous_child_model|
        vm_class = association_data.viewmodel_class_for_model!(previous_child_model.class)
        vm_class.new(previous_child_model)
      end

      if association_data.pointer_location == :remote
        if previous_child_viewmodel.present?
          # Clear the cached association so that AR's save behaviour doesn't
          # conflict with our explicit parent updates.  If we still have a child
          # after the update, we'll either call `Association#writer` or manually
          # fix the target cache after recursing in run!(). If we don't, we promise
          # that the child will no longer be attached in the database, so the new
          # cached data of nil will be correct.
          clear_association_cache(model, association_data.direct_reflection)
        end

        reparent_data =
          ParentData.new(association_data.direct_reflection.inverse_of, viewmodel)
      end

      if association_update_data.present?
        if association_data.referenced?
          # resolve reference string
          reference_string = association_update_data
          child_update, child_viewmodel = resolve_referenced_viewmodels(association_data, reference_string,
                                                                        previous_child_viewmodel, update_context)

          if reparent_data
            set_reference_update_parent(association_data, child_update, reparent_data)
          end

          if child_viewmodel.is_a?(ViewModel::Reference)
            update_context.defer_update(child_viewmodel, child_update)
          end
        else
          # Resolve direct children
          child_viewmodel =
            resolve_child_viewmodels(association_data, association_update_data, previous_child_viewmodel, update_context)

          child_update =
            if child_viewmodel.is_a?(ViewModel::Reference)
              update_context.new_deferred_update(child_viewmodel, association_update_data, reparent_to: reparent_data)
            else
              update_context.new_update(child_viewmodel, association_update_data, reparent_to: reparent_data)
            end
        end

        # Build the update if we've claimed it
        unless child_viewmodel.is_a?(ViewModel::Reference)
          child_update.build!(update_context)
        end
      else
        child_update = nil
        child_viewmodel = nil
      end

      # Handle changes
      if previous_child_viewmodel != child_viewmodel
        viewmodel.association_changed!(association_data.association_name)

        # free previous child if present and owned
        if previous_child_viewmodel.present? && association_data.owned?
          if association_data.pointer_location == :local
            # When we free a child that's pointed to from its old parent, we need to
            # clear the cached association to that old parent. If we don't do this,
            # then if the child gets claimed by a new parent and `save!`ed, AR will
            # re-establish the link from the old parent in the cache.

            # Ideally we want
            # model.association(...).inverse_reflection_for(previous_child_model), but
            # that's private.

            inverse_reflection = association_data.direct_reflection_inverse(previous_child_viewmodel.model.class)

            if inverse_reflection.present?
              clear_association_cache(previous_child_viewmodel.model, inverse_reflection)
            end
          end

          release_viewmodel(previous_child_viewmodel, association_data, update_context)
        end
      end

      child_update
    end

    def build_updates_for_collection_association(association_data, association_update, update_context)
      model = self.viewmodel.model

      # reference back to this model, so we can set the link while updating the children
      parent_data = ParentData.new(association_data.direct_reflection.inverse_of, viewmodel)

      # load children already attached to this model
      previous_child_viewmodels =
        model.public_send(association_data.direct_reflection.name).map do |child_model|
          child_viewmodel_class = association_data.viewmodel_class_for_model!(child_model.class)
          child_viewmodel_class.new(child_model)
        end

      if association_data.ordered?
        previous_child_viewmodels.sort_by!(&:_list_attribute)
      end

      if previous_child_viewmodels.present?
        # Clear the cached association so that AR's save behaviour doesn't
        # conflict with our explicit parent updates. If we still have children
        # after the update, we'll reset the target cache after recursing in
        # run(). If not, the empty array we cache here will be correct, because
        # previous children will be deleted or have had their parent pointers
        # updated.
        clear_association_cache(model, association_data.direct_reflection)
      end

      # Update contents are either UpdateData in the case of a nested
      # association, or reference strings in the case of a reference association.
      # The former are resolved with resolve_child_viewmodels, the latter with
      # resolve_referenced_viewmodels.
      resolve_child_data_reference = ->(child_data) do
        case child_data
        when UpdateData
          child_data.viewmodel_reference if child_data.id
        when String
          update_context.resolve_reference(child_data, nil).viewmodel_reference
        else
          raise ViewModel::DeserializationError::Internal.new(
                  "Unexpected child data type in collection update: #{child_data.class.name}")
        end
      end

      case association_update
      when AbstractCollectionUpdate::Replace
        child_datas = association_update.contents

      when AbstractCollectionUpdate::Functional
        # A fupdate isn't permitted to edit the same model twice.
        association_update.check_for_duplicates!(update_context, blame_reference)

        # Construct empty updates for previous children
        child_datas =
          previous_child_viewmodels.map do |previous_child_viewmodel|
            UpdateData.empty_update_for(previous_child_viewmodel)
          end

        # Insert or replace with either real UpdateData or reference strings
        association_update.actions.each do |fupdate|
          case fupdate
          when FunctionalUpdate::Append
            # If we're referring to existing members, ensure that they're removed before we append/insert
            existing_refs = fupdate.contents
                              .map(&resolve_child_data_reference)
                              .to_set

            child_datas.reject! do |child_data|
              child_ref = resolve_child_data_reference.(child_data)
              child_ref && existing_refs.include?(child_ref)
            end

            if fupdate.before || fupdate.after
              rel_ref = fupdate.before || fupdate.after

              # Find the relative insert location. This might be an empty
              # UpdateData from a previous child or an already-fupdated
              # reference string.
              index = child_datas.find_index do |child_data|
                rel_ref == resolve_child_data_reference.(child_data)
              end

              unless index
                raise ViewModel::DeserializationError::AssociatedNotFound.new(
                        association_data.association_name.to_s, rel_ref, blame_reference)
              end

              index += 1 if fupdate.after
              child_datas.insert(index, *fupdate.contents)

            else
              child_datas.concat(fupdate.contents)
            end

          when FunctionalUpdate::Remove
            removed_refs = fupdate.removed_vm_refs.to_set
            child_datas.reject! do |child_data|
              child_ref = resolve_child_data_reference.(child_data)
              removed_refs.include?(child_ref)
            end

          when FunctionalUpdate::Update
            # Already guaranteed that each ref has a single existing child attached
            new_child_datas = fupdate.contents.index_by(&resolve_child_data_reference)

            # Replace matched child_datas with the update contents.
            child_datas.map! do |child_data|
              child_ref = resolve_child_data_reference.(child_data)
              new_child_datas.delete(child_ref) { child_data }
            end

            # Assertion that all values in the update were found in child_datas
            unless new_child_datas.empty?
              raise ViewModel::DeserializationError::AssociatedNotFound.new(
                      association_data.association_name.to_s, new_child_datas.keys, blame_reference)
            end
          else
            raise ViewModel::DeserializationError::InvalidSyntax.new(
                    "Unknown functional update type: '#{fupdate.type}'",
                    blame_reference)
          end
        end
      end

      if association_data.referenced?
        # child_datas are either pre-resolved UpdateData (for non-fupdated
        # existing members) or reference strings. Resolve into pairs of
        # [UpdateOperation, ViewModel] if we can create or claim the
        # UpdateOperation or [UpdateOperation, ViewModelReference] otherwise.
        resolved_children =
          resolve_referenced_viewmodels(association_data, child_datas, previous_child_viewmodels, update_context)

        resolved_children.each do |child_update, child_viewmodel|
          set_reference_update_parent(association_data, child_update, parent_data)

          if child_viewmodel.is_a?(ViewModel::Reference)
            update_context.defer_update(child_viewmodel, child_update)
          end
        end

      else
        # child datas are all UpdateData
        child_viewmodels = resolve_child_viewmodels(association_data, child_datas, previous_child_viewmodels, update_context)

        resolved_children = child_datas.zip(child_viewmodels).map do |child_data, child_viewmodel|
          child_update =
            if child_viewmodel.is_a?(ViewModel::Reference)
              update_context.new_deferred_update(child_viewmodel, child_data, reparent_to: parent_data)
            else
              update_context.new_update(child_viewmodel, child_data, reparent_to: parent_data)
            end

          [child_update, child_viewmodel]
        end
      end

      # Calculate new positions for children if in a list. Ignore previous
      # positions (i.e. return nil) for unresolved references: they'll always
      # need to be updated anyway since their parent pointer will change.
      new_positions = Array.new(resolved_children.length)

      if association_data.ordered?
        set_position = ->(index, pos) { new_positions[index] = pos }

        get_previous_position = ->(index) do
          vm = resolved_children[index][1]
          vm._list_attribute unless vm.is_a?(ViewModel::Reference)
        end

        ActsAsManualList.update_positions(
          (0...resolved_children.size).to_a, # indexes
          position_getter: get_previous_position,
          position_setter: set_position)
      end

      resolved_children.zip(new_positions).each do |(child_update, child_viewmodel), new_position|
        child_update.reposition_to = new_position

        # Recurse into building child updates that we've claimed
        unless child_viewmodel.is_a?(ViewModel::Reference)
          child_update.build!(update_context)
        end
      end

      child_updates, child_viewmodels = resolved_children.transpose.presence || [[], []]

      # if the new children differ, including in order, mark that this
      # association has changed and release any no-longer-attached children
      if child_viewmodels != previous_child_viewmodels
        viewmodel.association_changed!(association_data.association_name)

        released_child_viewmodels = previous_child_viewmodels - child_viewmodels
        released_child_viewmodels.each do |vm|
          release_viewmodel(vm, association_data, update_context)
        end
      end

      child_updates
    end

    class ReferencedCollectionMember
      attr_reader   :indirect_viewmodel_reference, :direct_viewmodel
      attr_accessor :ref_string, :position

      def initialize(indirect_viewmodel_reference, direct_viewmodel)
        @indirect_viewmodel_reference = indirect_viewmodel_reference
        @direct_viewmodel             = direct_viewmodel
        if direct_viewmodel.class._list_member?
          @position = direct_viewmodel._list_attribute
        end
      end

      def ==(other)
        other.class == self.class &&
          other.indirect_viewmodel_reference == self.indirect_viewmodel_reference
      end

      alias eql? ==
    end

    # Helper class to wrap the previous members of a referenced collection and
    # provide update operations. No one member may be affected by more than one
    # update operation. Elements removed from the collection are collected as
    # `orphaned_members`."
    class MutableReferencedCollection
      attr_reader :members, :orphaned_members, :blame_reference

      def initialize(association_data, update_context, members, blame_reference)
        @association_data = association_data
        @update_context   = update_context
        @members          = members.dup
        @blame_reference  = blame_reference

        @orphaned_members = []

        @free_members_by_indirect_ref = @members.index_by(&:indirect_viewmodel_reference)
      end

      def replace(references)
        members.replace(claim_or_create_references(references))

        # Any unclaimed free members after building the update target are now
        # orphaned and their direct viewmodels can be released.
        orphaned_members.concat(free_members_by_indirect_ref.values)
        free_members_by_indirect_ref.clear
      end

      def insert_before(relative_to, references)
        insert_relative(relative_to, 0, references)
      end

      def insert_after(relative_to, references)
        insert_relative(relative_to, 1, references)
      end

      def concat(references)
        new_members = claim_or_create_references(references)
        remove_from_members(new_members)
        members.concat(new_members)
      end

      def remove(vm_references)
        removed_members = vm_references.map do |vm_ref|
          claim_existing_member(vm_ref)
        end
        remove_from_members(removed_members)
        orphaned_members.concat(removed_members)
      end

      def update(references)
        claim_existing_references(references)
      end

      private

      attr_reader :free_members_by_indirect_ref
      attr_reader :association_data, :update_context

      def insert_relative(relative_vm_ref, offset, references)
        new_members = claim_or_create_references(references)
        remove_from_members(new_members)

        index = members.find_index { |m| m.indirect_viewmodel_reference == relative_vm_ref }

        unless index
          raise ViewModel::DeserializationError::AssociatedNotFound.new(
            association_data.association_name.to_s, relative_vm_ref, blame_reference)
        end

        members.insert(index + offset, *new_members)
      end

      # Reclaim existing members corresponding to the specified references, or create new ones if not found.
      def claim_or_create_references(references)
        references.map do |ref_string|
          indirect_vm_ref = update_context.resolve_reference(ref_string, blame_reference).viewmodel_reference
          claim_or_create_member(indirect_vm_ref, ref_string)
        end
      end

      # Reclaim an existing member for an update and set its ref, or create a new one if not found.
      def claim_or_create_member(indirect_vm_ref, ref_string)
        member = free_members_by_indirect_ref.delete(indirect_vm_ref) do
          ReferencedCollectionMember.new(indirect_vm_ref, association_data.direct_viewmodel.for_new_model)
        end
        member.ref_string = ref_string
        member
      end

      # Reclaim existing members corresponding to the specified references or raise if not found.
      def claim_existing_references(references)
        references.each do |ref_string|
          indirect_vm_ref = update_context.resolve_reference(ref_string, blame_reference).viewmodel_reference
          claim_existing_member(indirect_vm_ref, ref_string)
        end
      end

      # Claim an existing collection member for the update and optionally set its ref.
      def claim_existing_member(indirect_vm_ref, ref_string = nil)
        member = free_members_by_indirect_ref.delete(indirect_vm_ref) do
          raise ViewModel::DeserializationError::AssociatedNotFound.new(
            association_data.association_name.to_s, indirect_vm_ref, blame_reference)
        end
        member.ref_string = ref_string if ref_string
        member
      end

      def remove_from_members(removed_members)
        s = removed_members.to_set
        members.reject! { |m| s.include?(m) }
      end
    end

    def build_updates_for_collection_referenced_association(association_data, association_update, update_context)
      model = self.viewmodel.model

      # We have two relationships here.
      #  - the relationship from us to the join table models:  direct
      #  - the relationship from the join table to the children: indirect

      direct_reflection         = association_data.direct_reflection
      indirect_reflection       = association_data.indirect_reflection
      direct_viewmodel_class    = association_data.direct_viewmodel
      indirect_association_data = association_data.indirect_association_data

      indirect_ref_for_direct_viewmodel = ->(direct_viewmodel) do
        direct_model    = direct_viewmodel.model
        model_class     = direct_model.association(indirect_reflection.name).klass
        model_id        = direct_model.public_send(indirect_reflection.foreign_key)
        viewmodel_class = indirect_association_data.viewmodel_class_for_model!(model_class)
        ViewModel::Reference.new(viewmodel_class, model_id)
      end

      previous_members = model.public_send(direct_reflection.name).map do |m|
        direct_vm              = direct_viewmodel_class.new(m)
        indirect_viewmodel_ref = indirect_ref_for_direct_viewmodel.(direct_vm)
        ReferencedCollectionMember.new(indirect_viewmodel_ref, direct_vm)
      end

      if association_data.ordered?
        previous_members.sort_by!(&:position)
      end

      target_collection = MutableReferencedCollection.new(
        association_data, update_context, previous_members, blame_reference)

      # All updates to referenced collections produce a complete target list of
      # ReferencedCollectionMembers including a ViewModel::Reference to the
      # indirect child, and an existing (from previous) or new ViewModel for the
      # direct child.
      #
      # Members participating in the update (all members in the case of Replace,
      # specified append or update members in the case of Functional) will also
      # include a reference string for the update operation for the indirect
      # child, which will be subsequently added to the new UpdateOperation for
      # the direct child.
      case association_update
      when ReferencedCollectionUpdate::Replace
        target_collection.replace(association_update.references)

      when ReferencedCollectionUpdate::Functional
        # Collection updates are a list of actions modifying the list
        # of indirect children.
        #
        # The target collection starts out as a copy of the previous collection
        # members, and is then mutated based on the actions specified. All
        # members added or modified by actions will have their `ref` set.

        association_update.check_for_duplicates!(update_context, self.viewmodel.blame_reference)

        association_update.actions.each do |fupdate|
          case fupdate
          when FunctionalUpdate::Append # Append new members, possibly relative to another member
            case
            when fupdate.before
              target_collection.insert_before(fupdate.before, fupdate.contents)
            when fupdate.after
              target_collection.insert_after(fupdate.after, fupdate.contents)
            else
              target_collection.concat(fupdate.contents)
            end

          when FunctionalUpdate::Remove
            target_collection.remove(fupdate.removed_vm_refs)

          when FunctionalUpdate::Update # Update contents of members already in the collection
            target_collection.update(fupdate.contents)

          else
            raise ArgumentError.new("Unknown functional update: '#{fupdate.class}'")
          end
        end

      else
        raise ViewModel::DeserializationError::InvalidSyntax.new("Unknown association_update type '#{association_update.class.name}'", blame_reference)
      end

      # We should now have an updated list `target_collection.members`,
      # containing members for the desired new collection in the order that we
      # want them, each of which has a `direct_viewmodel` set, and additionally
      # a `ref_string` set for those that participated in the update.
      if target_collection.members != previous_members
        viewmodel.association_changed!(association_data.association_name)
      end

      if association_data.ordered?
        ActsAsManualList.update_positions(target_collection.members)
      end

      parent_data = ParentData.new(direct_reflection.inverse_of, self.viewmodel)

      new_direct_updates = target_collection.members.map do |member|
        update_data = UpdateData.empty_update_for(member.direct_viewmodel)

        if (ref = member.ref_string)
          update_data.referenced_associations[indirect_reflection.name] = ref
        end

        update_context.new_update(member.direct_viewmodel, update_data,
                                  reparent_to:   parent_data,
                                  reposition_to: member.position)
          .build!(update_context)
      end

      # Members removed from the collection, either by `Remove` or by
      # not being included in the new Replace list can now be
      # released.
      target_collection.orphaned_members.each do |member|
        release_viewmodel(member.direct_viewmodel, association_data, update_context)
      end

      new_direct_updates
    end

    def release_viewmodel(viewmodel, association_data, update_context)
      self.released_children << update_context.release_viewmodel(viewmodel, association_data)
    end

    def clear_association_cache(model, reflection)
      association = model.association(reflection.name)
      association.target =
        if reflection.collection?
          []
        else
          nil
        end
    end

    def blame_reference
      self.viewmodel.blame_reference
    end

    def debug(msg)
      return unless ViewModel::Config.debug_deserialization

      ::ActiveRecord::Base.logger.try do |logger|
        logger.debug(msg)
      end
    end
  end
end
