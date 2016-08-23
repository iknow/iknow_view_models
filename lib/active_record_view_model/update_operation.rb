require "renum"

# Partially parsed tree of user-specified update hashes, created during deserialization.
class ActiveRecordViewModel
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
                  :reposition_to # if this node participates in a list under its parent, what should its position be?

    delegate :attributes, to: :update_data

    def initialize(viewmodel, update_data, reparent_to: nil, reposition_to: nil)
      self.viewmodel     = viewmodel
      self.update_data   = update_data
      self.points_to     = {}
      self.pointed_to    = {}
      self.reparent_to   = reparent_to
      self.reposition_to = reposition_to

      @run_state = RunState::Pending
      @association_changed = false
      @built = false
    end

    def viewmodel_reference
      unless viewmodel.model.new_record?
        ViewModelReference.from_viewmodel(viewmodel)
      end
    end

    def deferred?
      viewmodel.nil?
    end

    def built?
      @built
    end

    def association_changed!
      @association_changed = true
    end

    def association_changed?
      @association_changed
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
        viewmodel.visible!(context: deserialize_context)

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
          raise ViewModel::DeserializationError.new("Illegal member(s) #{bad_keys.inspect} when updating #{viewmodel.class.name}")
        end

        attributes.each do |attr_name, serialized_value|
          viewmodel.public_send("deserialize_#{attr_name}", serialized_value, deserialize_context: deserialize_context)
        end

        # Update points-to associations before save
        points_to.each do |association_data, child_operation|
          reflection = association_data.direct_reflection
          debug "-> #{debug_name}: Updating points-to association '#{reflection.name}'"

          association = model.association(reflection.name)
          child_model = if child_operation
                          child_operation.run!(deserialize_context: deserialize_context).model
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
        if model.changed? || association_changed?
          viewmodel.editable!(deserialize_context: deserialize_context)
        end

        debug "-> #{debug_name}: Saving"
        model.save!
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
            when ActiveRecordViewModel::UpdateOperation
              child_operation.run!(deserialize_context: deserialize_context).model
            when Array
              viewmodels = child_operation.map { |op| op.run!(deserialize_context: deserialize_context) }
              viewmodels.map(&:model)
            end

          association.target = new_target

          debug "<- #{debug_name}: Updated pointed-to association '#{reflection.name}'"
        end
      end

      debug "<- #{debug_name}: Leaving"

      @run_state = RunState::Run
      viewmodel
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

          if association_data.through?
            build_and_add_update_for_has_many_through(association_data, reference_string, update_context)
          else
            update = build_update_for_single_referenced_association(association_data, reference_string, update_context)
            add_update(association_data, update)
          end
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

      if reference_string.nil?
        nil
      else
        referred_update = update_context.resolve_reference(reference_string)

        unless association_data.accepts?(referred_update.viewmodel.class)
          raise ViewModel::DeserializationError.new("Association '#{association_data.direct_reflection.name}' can't refer to #{referred_update.viewmodel.class}") # TODO
        end

        referred_update.build!(update_context)
      end
    end

    # Resolve or construct viewmodels for incoming update data. Where a child
    # hash references an existing model not currently attached to this parent,
    # it must be found before recursing into that child. If the model is
    # available in released models we can take it and recurse, otherwise we must
    # return a ViewModelReference to be added to the worklist for deferred
    # resolution.
    def resolve_child_viewmodels(association_data, update_datas, previous_child_viewmodels, update_context)
      if self.viewmodel.class.respond_to?(:"resolve_#{association_data.direct_reflection.name}")
        return self.viewmodel.class.public_send(:"resolve_#{association_data.direct_reflection.name}", update_datas, previous_child_viewmodels)
      end

      was_singular = !update_datas.is_a?(Array)
      update_datas = Array.wrap(update_datas)
      previous_child_viewmodels = Array.wrap(previous_child_viewmodels)

      previous_by_key = previous_child_viewmodels.index_by do |vm|
        ViewModelReference.from_viewmodel(vm)
      end

      resolved_viewmodels =
        update_datas.map do |update_data|
        child_viewmodel_class = update_data.viewmodel_class
        key = ActiveRecordViewModel::ViewModelReference.new(child_viewmodel_class, update_data.id)

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

      was_singular ? resolved_viewmodels.first : resolved_viewmodels
    end

    def build_update_for_single_association(association_data, association_update_data, update_context)
      model = self.viewmodel.model

      previous_child_viewmodel = model.public_send(association_data.direct_reflection.name).try do |previous_child_model|
        vm_class = association_data.viewmodel_class_for_model(previous_child_model.class)
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
        self.association_changed!
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

          update_context.release_viewmodel(previous_child_viewmodel, association_data)
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
        when ActiveRecordViewModel::ViewModelReference # deferred
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
        when CollectionUpdate::Replace
          association_update.values

        when CollectionUpdate::Functional
          child_datas =
            previous_child_viewmodels.map do |previous_child_viewmodel|
              UpdateData.empty_update_for(previous_child_viewmodel)
            end

          # Each updated child must be unique
          duplicate_children = association_update
                                 .update_datas
                                 .duplicates { |upd| upd.viewmodel_reference if upd.id }
          if duplicate_children.present?
            formatted_invalid_ids = duplicate_children.keys.map(&:to_s).join(',')
            raise ViewModel::DeserializationError.new(
              "Duplicate functional update targets: #{formatted_invalid_ids}")
          end

          association_update.values.each do |fupdate|
            case fupdate
            when FunctionalUpdate::Append
              if fupdate.before || fupdate.after
                moved_refs  = fupdate.values.map(&:viewmodel_reference).to_set
                child_datas = child_datas.reject { |child| moved_refs.include?(child.viewmodel_reference) }

                ref   = (fupdate.before || fupdate.after).viewmodel_reference
                index = child_datas.find_index { |cd| cd.viewmodel_reference == ref }
                unless index
                  raise ViewModel::DeserializationError.new(
                    "Attempted to insert relative to reference that does not exist #{ref}")
                end

                index += 1 if fupdate.after
                child_datas.insert(index, *fupdate.values)

              else
                child_datas.concat(fupdate.values)

              end

            when FunctionalUpdate::Remove
              removed_refs = Set.new(fupdate.values.map(&:viewmodel_reference))
              child_datas.reject! { |child_data| removed_refs.include?(child_data.viewmodel_reference) }

            when FunctionalUpdate::Update
              new_datas = fupdate.values.group_by(&:viewmodel_reference)

              child_datas = child_datas.map do |child_data|
                ref = child_data.viewmodel_reference
                if new_datas.has_key?(ref)
                  # Already guaranteed that each ref has a single data attached
                  new_datas.delete(ref).first
                else
                  child_data
                end
              end

              # Assertion that all values in update_op.values are present in the collection
              unless new_datas.empty?
                raise ViewModel::DeserializationError.new('Stale update')
              end
            else
              raise ArgumentError.new("Unknown update type: '#{fupdate.type}'")
            end
          end

          child_datas
        end

      child_viewmodels = resolve_child_viewmodels(association_data, child_datas, previous_child_viewmodels, update_context)

      # if the new children differ, mark that one of our associations has
      # changed and release any no-longer-attached children
      if child_viewmodels != previous_child_viewmodels
        self.association_changed!
        released_child_viewmodels = previous_child_viewmodels - child_viewmodels
        released_child_viewmodels.each do |vm|
          update_context.release_viewmodel(vm, association_data)
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
          vm._list_attribute unless vm.is_a?(ActiveRecordViewModel::ViewModelReference)
        end

        ActsAsManualList.update_positions((0...child_viewmodels.size).to_a, # indexes
                                          position_getter: get_previous_position,
                                          position_setter: set_position)
      end

      # Recursively build update operations for children
      child_updates = child_viewmodels.zip(child_datas, positions).map do |child_viewmodel, association_update_data, position|
        case child_viewmodel
        when ActiveRecordViewModel::ViewModelReference # deferred
          reference = child_viewmodel
          update_context.new_deferred_update(reference, association_update_data, reparent_to: parent_data, reposition_to: position)
        else
          update_context.new_update(child_viewmodel, association_update_data, reparent_to: parent_data, reposition_to: position).build!(update_context)
        end
      end

      child_updates
    end

    # TODO name isn't generic like all others; why not _collection_referenced_?
    def build_and_add_update_for_has_many_through(association_data, reference_strings, update_context)
      model = self.viewmodel.model

      direct_reflection         = association_data.direct_reflection
      indirect_reflection       = association_data.indirect_reflection
      through_viewmodel         = association_data.through_viewmodel
      indirect_association_data = association_data.indirect_association_data

      viewmodel_reference_for_indirect_model = ->(through_model) do
        model_class     = through_model.association(indirect_reflection.name).klass
        model_id        = through_model.public_send(indirect_reflection.foreign_key)
        viewmodel_class = indirect_association_data.viewmodel_class_for_model(model_class)
        ViewModelReference.new(viewmodel_class, model_id)
      end

      # we want to set position => we need to reimplement the through handling
      previous_through_children =
        model
          .public_send(direct_reflection.name)
          .tap { |x| x.sort_by(&through_viewmodel._list_attribute_name) if through_viewmodel._list_member? }
          .group_by(&viewmodel_reference_for_indirect_model)

      # To try to reduce list position churn in the case of multiple
      # associations to a single model, we keep the previous_through_children
      # values sorted, and take the first element from the list each time we
      # find a reference to it in the update data.

      new_through_viewmodels = reference_strings.map do |ref|
        target_reference = update_context.resolve_reference(ref).viewmodel_reference

        existing_through_record =
          (previous_through_children[target_reference].try(:shift) if target_reference)

        if existing_through_record
          through_viewmodel.new(existing_through_record)
        else
          through_viewmodel.for_new_model
        end
      end

      positions = Array.new(new_through_viewmodels.length)
      if through_viewmodel._list_member?
        # It's always fine to use a position, since this is always owned data (no moves, so no positions to ignore.)
        get_position = ->(index)     { new_through_viewmodels[index]._list_attribute }
        set_position = ->(index, pos){ positions[index] = pos }

        ActsAsManualList.update_positions((0...new_through_viewmodels.size).to_a, # indexes
                                          position_getter: get_position,
                                          position_setter: set_position)
      end

      new_through_updates = new_through_viewmodels.zip(reference_strings, positions).map do |viewmodel, ref, position|
        update_data = UpdateData.empty_update_for(viewmodel)
        update_data.referenced_associations[indirect_reflection.name] = ref # TODO layering violation

        parent_data = ParentData.new(direct_reflection.inverse_of, self.viewmodel)
        update_context.new_update(viewmodel, update_data,
                                  reparent_to: parent_data,
                                  reposition_to: position)
          .build!(update_context)
      end


      add_update(association_data, new_through_updates)

      # Anything left in the list of previous_children is now garbage, and
      # should be released. We assert it's never going to be reclaimed.

      previous_through_children.each do |_, children|
        children.each do |child|
          update_context.release_viewmodel(through_viewmodel.new(child), association_data)
        end
      end
    end

    def clear_association_cache(model, reflection)
      association = model.association(reflection.name)
      if reflection.collection?
        association.target = []
      else
        association.target = nil
      end
    end

    def debug(msg)
      ActiveRecord::Base.logger.try do |logger|
        logger.debug(msg)
      end
    end

  end
end
