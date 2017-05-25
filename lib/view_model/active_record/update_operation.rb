require "renum"

# Partially parsed tree of user-specified update hashes, created during deserialization.
class ViewModel::ActiveRecord
  using Collections

  class UpdateOperation
    # inverse association and record to update a change in parent from a child
    ParentData = Struct.new(:association_reflection, :viewmodel)

    enum :RunState, [:Pending, :Running, :Run]

    attr_accessor :viewmodel,
                  :update_data,
                  :points_to,  # AssociationData => UpdateOperation (returns single new viewmodel to update fkey)
                  :pointed_to, # AssociationData => UpdateOperation(s) (returns viewmodel(s) with which to update assoc cache)
                  :reparent_to,  # If node needs to update its pointer to a new parent, ParentData for the parent
                  :reposition_to, # if this node participates in a list under its parent, what should its position be?
                  :released_children # Set of children that have been released

    delegate :attributes, to: :update_data

    def initialize(viewmodel, update_data, reparent_to: nil, reposition_to: nil)
      self.viewmodel         = viewmodel
      self.update_data       = update_data
      self.points_to         = {}
      self.pointed_to        = {}
      self.reparent_to       = reparent_to
      self.reposition_to     = reposition_to
      self.released_children = []

      @run_state = RunState::Pending
      @changed_associations = []
      @built = false
    end

    def viewmodel_reference
      unless viewmodel.model.new_record?
        viewmodel.to_reference
      end
    end

    def deferred?
      viewmodel.nil?
    end

    def built?
      @built
    end

    def association_changed!(association_name)
      @changed_associations << association_name.to_s
    end

    def associations_changed?
      @changed_associations.present?
    end

    # Evaluate a built update tree, applying and saving changes to the models.
    def run!(deserialize_context:)
      raise "Not yet built!" unless built? # TODO

      case @run_state
      when RunState::Running
        raise "Cycle! Bad!" # TODO
      when RunState::Run
        return viewmodel
      end

      @run_state = RunState::Running

      model = viewmodel.model

      debug_name = "#{model.class.name}:#{model.id || '<new>'}"
      debug "-> #{debug_name}: Entering"

      model.class.transaction do
        deserialize_context.visible!(viewmodel)

        # Check that the record is eligible to be edited before any changes are
        # made. A failure here becomes an error once we've detected a change
        # being made.
        initial_editability = deserialize_context.initial_editability(viewmodel)

        viewmodel.before_deserialize(deserialize_context: deserialize_context)

        # update parent association
        if reparent_to.present?
          debug "-> #{debug_name}: Updating parent pointer to '#{reparent_to.viewmodel.class.view_name}:#{reparent_to.viewmodel.id}'"
          association = model.association(reparent_to.association_reflection.name)
          association.replace(reparent_to.viewmodel.model)
          debug "<- #{debug_name}: Updated parent pointer"
        end

        # update position
        if reposition_to.present?
          debug "-> #{debug_name}: Updating position to #{reposition_to}"
          viewmodel._list_attribute = reposition_to
        end

        # update user-specified attributes
        valid_members = viewmodel.class._members.keys.map(&:to_s).to_set
        bad_keys = attributes.keys.reject { |k| valid_members.include?(k) }
        if bad_keys.present?
          raise_deserialization_error("Illegal attribute/association(s) #{bad_keys.inspect} for viewmodel #{viewmodel.class.view_name}")
        end

        attributes.each do |attr_name, serialized_value|
          # Note that the VM::AR deserialization tree asserts ownership over any
          # references it's provided, and so they're intentionally not passed on
          # to attribute deserialization for use by their `using:` viewmodels. A
          # (better?) alternative would be to provide them as reference-only
          # hashes, to indicate that no modification can be permitted.
          viewmodel.public_send("deserialize_#{attr_name}", serialized_value,
                                references: {},
                                deserialize_context: deserialize_context)
        end

        # Update points-to associations before save
        points_to.each do |association_data, child_operation|
          reflection = association_data.direct_reflection
          debug "-> #{debug_name}: Updating points-to association '#{reflection.name}'"

          association = model.association(reflection.name)
          child_model = if child_operation
                          child_operation.run!(deserialize_context: deserialize_context.for_child(viewmodel)).model
                        else
                          nil
                        end
          association.replace(child_model)
          debug "<- #{debug_name}: Updated points-to association '#{reflection.name}'"
        end

        # Placing the edit check here allows it to consider the previous and
        # current state of the model before it is saved. For example, but
        # comparing #foo, #foo_was, #new_record?. Note that edit checks for
        # deletes are handled elsewhere.

        changed_attributes = model.changed

        if model.class.locking_enabled?
          changed_attributes.delete(model.class.locking_column)
        end

        if changed_attributes.present? || associations_changed?
          changes = ViewModel::DeserializeContext::Changes.new(new:                  model.new_record?,
                                                               changed_attributes:   changed_attributes,
                                                               changed_associations: @changed_associations)

          viewmodel.before_save(changes, deserialize_context: deserialize_context)

          # The hook before this might have caused additional changes. All changes should be checked by the policy,
          # so we have to recalculate the change set.

          changes = ViewModel::DeserializeContext::Changes.new(new:                  model.new_record?,
                                                               changed_attributes:   changed_attributes,
                                                               changed_associations: @changed_associations)

          deserialize_context.editable!(viewmodel,
                                        initial_editability: initial_editability,
                                        changes: changes)
        end

        debug "-> #{debug_name}: Saving"
        begin
          model.save!
        rescue ::ActiveRecord::RecordInvalid => ex
          raise_deserialization_error(ex.message, model.errors.messages, error: ViewModel::DeserializationError::Validation)
        rescue ::ActiveRecord::StaleObjectError => ex
          raise_deserialization_error(ex.message, error: ViewModel::DeserializationError::LockFailure)
        end
        debug "<- #{debug_name}: Saved"

        # Update association cache of pointed-from associations after save: the
        # child update will have saved the pointer.
        pointed_to.each do |association_data, child_operation|
          reflection = association_data.direct_reflection

          debug "-> #{debug_name}: Updating pointed-to association '#{reflection.name}'"

          association = model.association(reflection.name)
          new_target =
            case child_operation
            when nil
              nil
            when ViewModel::ActiveRecord::UpdateOperation
              child_operation.run!(deserialize_context: deserialize_context.for_child(viewmodel)).model
            when Array
              viewmodels = child_operation.map { |op| op.run!(deserialize_context: deserialize_context.for_child(viewmodel)) }
              viewmodels.map(&:model)
            end

          association.target = new_target

          debug "<- #{debug_name}: Updated pointed-to association '#{reflection.name}'"
        end
      end

      if self.released_children.present?
        debug "-> #{debug_name}: Checking released children permissions"
        self.released_children.reject(&:claimed?).each do |released_child|
          debug "-> #{debug_name}: Checking #{released_child.viewmodel.to_reference}"
          child_context = deserialize_context.for_child(viewmodel)
          child_vm = released_child.viewmodel
          child_context.visible!(child_vm)
          initial_editability = child_context.initial_editability(child_vm)
          child_context.editable!(child_vm,
                                  initial_editability: initial_editability,
                                  changes: ViewModel::DeserializeContext::Changes.new(deleted: true))
        end
        debug "<- #{debug_name}: Finished checking released children permissions"
      end

      debug "<- #{debug_name}: Leaving"

      @run_state = RunState::Run
      viewmodel
    rescue ::ActiveRecord::StatementInvalid, ::ActiveRecord::InvalidForeignKey, ::ActiveRecord::RecordNotSaved => ex
      raise_deserialization_error(ex.message)
    end

    # Recursively builds UpdateOperations for the associations in our UpdateData
    def build!(update_context)
      raise "Cannot build deferred update" if deferred? # TODO
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
          else
            build_update_for_single_referenced_association(association_data, reference_string, update_context)
          end

        add_update(association_data, update)
      end

      @built = true
      self
    end

    def add_update(association_data, update)
      target =
        case association_data.pointer_location
        when :remote; pointed_to
        when :local;  points_to
        end

      target[association_data] = update
    end

    private

    def build_update_for_single_referenced_association(association_data, reference_string, update_context)
      # TODO intern loads for shared items so we only load them once
      model = self.viewmodel.model
      previous_child_viewmodel = model.public_send(association_data.direct_reflection.name).try do |previous_child_model|
        vm_class = association_data.viewmodel_class_for_model!(previous_child_model.class)
        vm_class.new(previous_child_model)
      end

      if reference_string.nil?
        referred_update    = nil
        referred_viewmodel = nil
      else
        referred_update    = update_context.resolve_reference(reference_string)
        referred_viewmodel = referred_update.viewmodel

        unless association_data.accepts?(referred_viewmodel.class)
          raise_deserialization_error("Type error: association '#{association_data.direct_reflection.name}'"\
                                      " can't refer to #{referred_viewmodel.class}")
        end

        referred_update.build!(update_context)
      end

      if previous_child_viewmodel != referred_viewmodel
        self.association_changed!(association_data.association_name)
      end

      referred_update
    end

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

    def build_update_for_single_association(association_data, association_update_data, update_context)
      model = self.viewmodel.model

      previous_child_viewmodel = model.public_send(association_data.direct_reflection.name).try do |previous_child_model|
        vm_class = association_data.viewmodel_class_for_model!(previous_child_model.class)
        vm_class.new(previous_child_model)
      end

      if previous_child_viewmodel.present?
        # Clear the cached association so that AR's save behaviour doesn't
        # conflict with our explicit parent updates.  If we still have a child
        # after the update, we'll either call `Association#replace` or manually
        # fix the target cache after recursing in run!(). If we don't, we promise
        # that the child will no longer be attached in the database, so the new
        # cached data of nil will be correct.
        clear_association_cache(model, association_data.direct_reflection)
      end

      child_viewmodel =
        if association_update_data.present?
          resolve_child_viewmodels(association_data, association_update_data, previous_child_viewmodel, update_context)
        end

      if previous_child_viewmodel != child_viewmodel
        self.association_changed!(association_data.association_name)
        # free previous child if present
        if previous_child_viewmodel.present?
          if association_data.pointer_location == :local
            # When we free a child that's pointed to from its old parent, we need to
            # clear the cached association to that old parent. If we don't do this,
            # then if the child gets claimed by a new parent and `save!`ed, AR will
            # re-establish the link from the old parent in the cache.

            # Ideally we want
            # model.association(...).inverse_reflection_for(previous_child_model), but
            # that's private.

            inverse_reflection =
              if association_data.direct_reflection.polymorphic?
                association_data.direct_reflection.polymorphic_inverse_of(previous_child_viewmodel.model.class)
              else
                association_data.direct_reflection.inverse_of
              end

            if inverse_reflection.present?
              clear_association_cache(previous_child_viewmodel.model, inverse_reflection)
            end
          end

          release_viewmodel(previous_child_viewmodel, association_data, update_context)
        end
      end

      # Construct and return update for new child viewmodel
      if child_viewmodel.present?
        # If the association's pointer is in the child, need to provide it with a
        # ParentData to update
        parent_data =
          if association_data.pointer_location == :remote
            ParentData.new(association_data.direct_reflection.inverse_of, viewmodel)
          else
            nil
          end

        case child_viewmodel
        when ViewModel::Reference # deferred
          vm_ref = child_viewmodel
          update_context.new_deferred_update(vm_ref, association_update_data, reparent_to: parent_data)
        else
          update_context.new_update(child_viewmodel, association_update_data, reparent_to: parent_data).build!(update_context)
        end
      end
    end

    def build_updates_for_collection_association(association_data, association_update, update_context)
      model = self.viewmodel.model

      # reference back to this model, so we can set the link while updating the children
      parent_data = ParentData.new(association_data.direct_reflection.inverse_of, viewmodel)

      # load children already attached to this model
      child_viewmodel_class     = association_data.viewmodel_class
      previous_child_viewmodels =
        model.public_send(association_data.direct_reflection.name).map do |child_model|
          child_viewmodel_class.new(child_model)
        end
      if child_viewmodel_class._list_member?
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

      child_datas =
        case association_update
        when OwnedCollectionUpdate::Replace
          association_update.update_datas

        when OwnedCollectionUpdate::Functional
          child_datas =
            previous_child_viewmodels.map do |previous_child_viewmodel|
              UpdateData.empty_update_for(previous_child_viewmodel)
            end

          association_update.check_for_duplicates!(update_context, self.viewmodel.blame_reference)

          association_update.actions.each do |fupdate|
            case fupdate
            when FunctionalUpdate::Append
              if fupdate.before || fupdate.after
                moved_refs  = fupdate.contents.map(&:viewmodel_reference).to_set
                child_datas = child_datas.reject { |child| moved_refs.include?(child.viewmodel_reference) }

                ref         = fupdate.before || fupdate.after
                index       = child_datas.find_index { |cd| cd.viewmodel_reference == ref }
                unless index
                  raise ViewModel::DeserializationError::NotFound.new(
                    "Attempted to insert relative to reference that does not exist #{ref}",
                    [ref])
                end

                index += 1 if fupdate.after
                child_datas.insert(index, *fupdate.contents)

              else
                child_datas.concat(fupdate.contents)

              end

            when FunctionalUpdate::Remove
              removed_refs = fupdate.removed_vm_refs.to_set
              child_datas.reject! { |child_data| removed_refs.include?(child_data.viewmodel_reference) }

            when FunctionalUpdate::Update
              # Already guaranteed that each ref has a single data attached
              new_datas = fupdate.contents.index_by(&:viewmodel_reference)

              child_datas = child_datas.map do |child_data|
                ref = child_data.viewmodel_reference
                new_datas.delete(ref) { child_data }
              end

              # Assertion that all values in update_op.values are present in the collection
              unless new_datas.empty?
                raise_deserialization_error(
                  "Stale functional update for association '#{association_data.direct_reflection.name}' - "\
                  "could not match referenced viewmodels: [#{new_datas.keys.map(&:to_s).join(', ')}]",
                  error: ViewModel::DeserializationError::NotFound)
              end
            else
              raise_deserialization_error("Unknown functional update type: '#{fupdate.type}'")
            end
          end

          child_datas
        end

      child_viewmodels = resolve_child_viewmodels(association_data, child_datas, previous_child_viewmodels, update_context)

      # if the new children differ, mark that one of our associations has
      # changed and release any no-longer-attached children
      if child_viewmodels != previous_child_viewmodels
        self.association_changed!(association_data.association_name)
        released_child_viewmodels = previous_child_viewmodels - child_viewmodels
        released_child_viewmodels.each do |vm|
          release_viewmodel(vm, association_data, update_context)
        end
      end

      # Calculate new positions for children if in a list. Ignore previous
      # positions for unresolved references: they'll always need to be updated
      # anyway since their parent pointer will change.
      positions = Array.new(child_viewmodels.length)
      if association_data.viewmodel_class._list_member?
        set_position = ->(index, pos){ positions[index] = pos }
        get_previous_position = ->(index) do
          vm = child_viewmodels[index]
          vm._list_attribute unless vm.is_a?(ViewModel::Reference)
        end

        ActsAsManualList.update_positions((0...child_viewmodels.size).to_a, # indexes
                                          position_getter: get_previous_position,
                                          position_setter: set_position)
      end

      # Recursively build update operations for children
      child_updates = child_viewmodels.zip(child_datas, positions).map do |child_viewmodel, association_update_data, position|
        case child_viewmodel
        when ViewModel::Reference # deferred
          reference = child_viewmodel
          update_context.new_deferred_update(reference, association_update_data, reparent_to: parent_data, reposition_to: position)
        else
          update_context.new_update(child_viewmodel, association_update_data, reparent_to: parent_data, reposition_to: position).build!(update_context)
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

      alias :eql? :==
    end

    # Helper class to wrap the previous members of a referenced collection and
    # provide update operations. No one member may be affected by more than one
    # update operation. Elements removed from the collection are collected as
    # `orphaned_members`."
    class MutableReferencedCollection
      attr_reader :members, :orphaned_members

      def initialize(association_data, update_context, members)
        @association_data = association_data
        @update_context   = update_context

        @members          = members.dup
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
          raise ViewModel::DeserializationError::NotFound.new(
            "Attempted to insert relative to reference that does not exist #{relative_vm_ref}",
            [relative_vm_ref])
        end

        members.insert(index + offset, *new_members)
      end

      # Reclaim existing members corresponding to the specified references, or create new ones if not found.
      def claim_or_create_references(references)
        references.map do |ref_string|
          indirect_vm_ref = update_context.resolve_reference(ref_string).viewmodel_reference
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
          indirect_vm_ref = update_context.resolve_reference(ref_string).viewmodel_reference
          claim_existing_member(indirect_vm_ref, ref_string)
        end
      end

      # Claim an existing collection member for the update and optionally set its ref.
      def claim_existing_member(indirect_vm_ref, ref_string = nil)
        member = free_members_by_indirect_ref.delete(indirect_vm_ref) do
          raise ViewModel::DeserializationError::NotFound.new(
            "Stale functional update for association '#{association_data.direct_reflection.name}' - "\
                  "could not match referenced viewmodel: '#{indirect_vm_ref}'")
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

      if direct_viewmodel_class._list_member?
        previous_members.sort_by!(&:position)
      end

      target_collection = MutableReferencedCollection.new(
        association_data, update_context, previous_members)

      # All updates to shared collections produce a complete target list of
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
        raise_deserialization_error("Unknown association_update type '#{association_update.class.name}'")
      end

      # We should now have an updated list of `target_collection_members`, each
      # of which has a `direct_viewmodel` set, and additionally a `ref_string`
      # set for those that participated in the update.

      if target_collection.members != previous_members
        self.association_changed!(association_data.association_name)
      end

      if direct_viewmodel_class._list_member?
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
      if reflection.collection?
        association.target = []
      else
        association.target = nil
      end
    end

    def raise_deserialization_error(msg, *args, error: ViewModel::DeserializationError)
      raise error.new(msg, self.viewmodel.blame_reference, *args)
    end

    def debug(msg)
      ::ActiveRecord::Base.logger.try do |logger|
        logger.debug(msg)
      end
    end

  end
end
