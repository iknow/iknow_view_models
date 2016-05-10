require "renum"

# Partially parsed tree of user-specified update hashes, created during deserialization.
class ActiveRecordViewModel
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
        # update parent association
        if reparent_to.present?
          debug "-> #{debug_name}: Updating parent pointer to '#{reparent_to.viewmodel.class.view_name}:#{reparent_to.viewmodel.id}'"
          association = model.association(reparent_to.association_reflection.name)
          association.replace(reparent_to.viewmodel.model)
          debug "<- #{debug_name}: Updated parent pointer"
        end

        # update position
        if reposition_to.present?
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
          debug "-> #{debug_name}: Updating points-to association '#{association_data.name}'"

          association = model.association(association_data.name)
          child_model = if child_operation
                          child_operation.run!(deserialize_context: deserialize_context).model
                        else
                          nil
                        end
          association.replace(child_model)
          debug "<- #{debug_name}: Updated points-to association '#{association_data.name}'"
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
          debug "-> #{debug_name}: Updating pointed-to association '#{association_data.name}'"

          association = model.association(association_data.name)

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

          debug "<- #{debug_name}: Updated pointed-to association '#{association_data.name}'"
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

        update =
          build_update_for_single_referenced_association(association_data, reference_string, update_context)

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

      if reference_string.nil?
        nil
      else
        referred_update = update_context.resolve_reference(reference_string)

        unless association_data.accepts?(referred_update.viewmodel.class)
          raise ViewModel::DeserializationError.new("Association '#{association_data.reflection.name}' can't refer to #{referred_update.viewmodel.class}") # TODO
        end

        referred_update.build!(update_context)
      end
    end


    def build_update_for_single_association(association_data, association_update_data, update_context)
      model = self.viewmodel.model

      previous_child_model = model.public_send(association_data.name)

      if previous_child_model.present?
        previous_child_viewmodel_class = association_data.viewmodel_class_for_model(previous_child_model.class)
        previous_child_viewmodel = previous_child_viewmodel_class.new(previous_child_model)
        previous_child_key = ActiveRecordViewModel::ViewModelReference.from_viewmodel(previous_child_viewmodel)

        # Clear the cached association so that AR's save behaviour doesn't
        # conflict with our explicit parent updates.  If we still have a child
        # after the update, we'll either call `Association#replace` or manually
        # fix the target cache after recursing in run!(). If we don't, we promise
        # that the child will no longer be attached in the database, so the new
        # cached data of nil will be correct.
        clear_association_cache(model, association_data.reflection)
      end

      child_update = nil
      if association_update_data.present?
        id = association_update_data.id
        child_viewmodel_class = association_update_data.viewmodel_class

        child_viewmodel =
          if id.nil?
            self.association_changed!
            child_viewmodel_class.new
          else
            key = ActiveRecordViewModel::ViewModelReference.new(child_viewmodel_class, id)
            case
            when taken_child = update_context.try_take_released_viewmodel(key)
              self.association_changed!
              taken_child
            when key == previous_child_key
              previous_child_viewmodel.tap { previous_child_viewmodel = nil }
            else
              # not-yet-seen child: create a deferred update
              self.association_changed!
              key
            end
          end

        # If the association's pointer is in the child, need to provide it with a
        # ParentData to update
        parent_data =
          if association_data.pointer_location == :remote
            ParentData.new(association_data.reflection.inverse_of, viewmodel)
          else
            nil
          end

        child_update =
          case child_viewmodel
          when ActiveRecordViewModel::ViewModelReference # deferred
            vm_ref = child_viewmodel
            update_context.new_deferred_update(vm_ref, association_update_data, reparent_to: parent_data)
          else
            update_context.new_update(child_viewmodel, association_update_data, reparent_to: parent_data).build!(update_context)
          end
      end

      # Release the previous child if not reclaimed
      if previous_child_viewmodel.present?
        self.association_changed!
        if association_data.pointer_location == :local
          # When we free a child that's pointed to from its old parent, we need to
          # clear the cached association to that old parent. If we don't do this,
          # then if the child gets claimed by a new parent and `save!`ed, AR will
          # re-establish the link from the old parent in the cache.

          # Ideally we want
          # model.association(...).inverse_reflection_for(previous_child_model), but
          # that's private.

          inverse_reflection =
            if association_data.reflection.polymorphic?
              association_data.reflection.polymorphic_inverse_of(previous_child_model.class)
            else
              association_data.reflection.inverse_of
            end

          if inverse_reflection.present?
            clear_association_cache(previous_child_viewmodel.model, inverse_reflection)
          end
        end

        update_context.release_viewmodel(previous_child_viewmodel, association_data)
      end

      child_update
    end

    def build_updates_for_collection_association(association_data, association_update_datas, update_context)
      model = self.viewmodel.model

      child_viewmodel_class = association_data.viewmodel_class

      # reference back to this model, so we can set the link while updating the children
      parent_data = ParentData.new(association_data.reflection.inverse_of, viewmodel)

      unless association_update_datas.is_a?(Array)
        raise ViewModel::DeserializationError.new("Invalid hash data array for multiple association: '#{association_update_datas.inspect}'")
      end

      # load children already attached to this model
      previous_children = model.public_send(association_data.name).index_by(&:id)

      if previous_children.present?
        # Clear the cached association so that AR's save behaviour doesn't
        # conflict with our explicit parent updates. If we still have children
        # after the update, we'll reset the target cache after recursing in
        # run(). If not, the empty array we cache here will be correct, because
        # previous children will be deleted or have had their parent pointers
        # updated.
        clear_association_cache(model, association_data.reflection)
      end

      # Construct viewmodels for incoming hash data. Where a child hash references
      # an existing model not currently attached to this parent, it must be found
      # before recursing into that child. If the model is available in released
      # models we can recurse into them, otherwise we must attach a stub
      # UpdateOperation (and add it to the worklist to process later)
      child_viewmodels = association_update_datas.map do |association_update_data|
        id  = association_update_data.id
        key = ActiveRecordViewModel::ViewModelReference.new(child_viewmodel_class, id)

        case
        when id.nil?
          self.association_changed!
          child_viewmodel_class.new
        when existing_child = previous_children.delete(id)
          child_viewmodel_class.new(existing_child)
        when taken_child = update_context.try_take_released_viewmodel(key)
          self.association_changed!
          taken_child
        else
          # Refers to child that hasn't yet been seen: create a deferred update.
          self.association_changed!
          key
        end
      end

      # release previously attached children that are no longer referred to
      previous_children.each_value do |child_model|
        self.association_changed!
        update_context.release_viewmodel(
          child_viewmodel_class.new(child_model), association_data)
      end

      # Calculate new positions for children if in a list. Ignore previous
      # positions for unresolved references: they'll always need to be updated
      # anyway since their parent pointer will change.
      positions = Array.new(child_viewmodels.length)
      if child_viewmodel_class._list_member?
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
      child_updates = child_viewmodels.zip(association_update_datas, positions).map do |child_viewmodel, association_update_data, position|
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
