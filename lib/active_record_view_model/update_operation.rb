require "renum"

# Partially parsed tree of user-specified update hashes, created during deserialization.
class ActiveRecordViewModel::UpdateOperation
  # inverse association and record to update a change in parent from a child
  ParentData = Struct.new(:association_reflection, :viewmodel)

  enum :RunState, [:Pending, :Running, :Run]

  attr_accessor :viewmodel,
                :subtree_hash,
                :attributes, # attr => serialized value
                :points_to,  # AssociationData => UpdateOperation (returns single new viewmodel to update fkey)
                :pointed_to, # AssociationData => UpdateOperation(s) (returns viewmodel(s) with which to update assoc cache)
                :reparent_to,  # If node needs to update its pointer to a new parent, ParentData for the parent
                :reposition_to # if this node participates in a list under its parent, what should its position be?

  # The reference of the viewmodel being updated or deleted. Nil when the
  # viewmodel is creating a new model.
  attr_reader :viewmodel_reference

  def initialize(viewmodel, subtree_hash, reparent_to: nil, reposition_to: nil, viewmodel_reference: nil)
    self.viewmodel     = viewmodel
    self.subtree_hash  = subtree_hash
    self.attributes    = {}
    self.points_to     = {}
    self.pointed_to    = {}
    self.reparent_to   = reparent_to
    self.reposition_to = reposition_to

    @run_state = RunState::Pending
    @association_changed = false

    if viewmodel_reference.nil? && viewmodel.nil?
      raise 'Need either explicit reference or a viewmodel to update'
    else
      @viewmodel_reference =
        if viewmodel_reference
          viewmodel_reference
        elsif !viewmodel.model.new_record?
          ActiveRecordViewModel::ViewModelReference.new(viewmodel.class, viewmodel.model.id)
        end
    end
  end

  def deferred?
    viewmodel.nil?
  end

  def built?
    subtree_hash.nil?
  end

  def association_changed!
    @association_changed = true
  end

  def association_changed?
    @association_changed
  end

  # Determines user intent from a hash, extracting identity metadata and
  # returning a tuple of viewmodel_class, id, and a pure-data hash. The input
  # hash will be consumed.
  def self.extract_metadata_from_hash(hash)
    valid_subtree_hash!(hash)

    unless hash.has_key?(ActiveRecordViewModel::TYPE_ATTRIBUTE)
      raise ViewModel::DeserializationError.new("Missing '#{ActiveRecordViewModel::TYPE_ATTRIBUTE}' field in update hash: '#{hash.inspect}'")
    end

    id        = hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
    type_name = hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)

    viewmodel_class = ActiveRecordViewModel.for_view_name(type_name)

    return viewmodel_class, id, hash
  end

  def self.valid_subtree_hash!(subtree_hash)
    unless subtree_hash.is_a?(Hash)
      raise ViewModel::DeserializationError.new("Invalid data to deserialize - not a hash: '#{subtree_hash.inspect}'")
    end
    unless subtree_hash.has_key?(ActiveRecordViewModel::TYPE_ATTRIBUTE)
      raise ViewModel::DeserializationError.new("Invalid update hash data - '#{ActiveRecordViewModel::TYPE_ATTRIBUTE}' attribute missing: #{subtree_hash.inspect}")
    end
  end

  def self.valid_reference_hash!(subtree_hash)
    unless subtree_hash.is_a?(Hash)
      raise ViewModel::DeserializationError.new("Invalid data to deserialize - not a hash: '#{subtree_hash.inspect}'")
    end
    unless subtree_hash.size == 1
      raise ViewModel::DeserializationError.new("Invalid reference hash data - must not contain keys besides '#{ActiveRecordViewModel::REFERENCE_ATTRIBUTE}': #{subtree_hash.keys.inspect}")
    end
    unless subtree_hash.has_key?(ActiveRecordViewModel::REFERENCE_ATTRIBUTE)
      raise ViewModel::DeserializationError.new("Invalid reference hash data - '#{ActiveRecordViewModel::REFERENCE_ATTRIBUTE}' attribute missing: #{subtree_hash.inspect}")
    end
  end

  # Evaluate a built update tree, applying and saving changes to the models.
  def run!(view_context:)
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
        viewmodel.public_send("deserialize_#{attr_name}", serialized_value, view_context: view_context)
      end

      # Update points-to associations before save
      points_to.each do |association_data, child_operation|
        debug "-> #{debug_name}: Updating points-to association '#{association_data.name}'"

        association = model.association(association_data.name)
        child_model = if child_operation
                        child_operation.run!(view_context: view_context).model
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
        viewmodel.editable!(view_context: view_context)
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
            child_operation.run!(view_context: view_context).model
          when Array
            viewmodels = child_operation.map { |op| op.run!(view_context: view_context) }
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

  # Splits an update hash up into attributes, points-to associations and
  # pointed-to associations (in the context of our viewmodel), and recurses
  # into associations to create updates.
  def build!(update_context)
    raise "Cannot build deferred update" if deferred? # TODO
    return self if built?

    subtree_hash.each do |k, v|
      case self.viewmodel.class._members[k]
      when :attribute
        attributes[k] = v

      when :association
        association_name = k
        association_hash = v

        association_data = self.viewmodel.class._association_data(association_name)

        if association_data.collection?
          self.pointed_to[association_data] = build_updates_for_collection_association(association_data, association_hash, update_context)
        else
          target =
            case association_data.pointer_location
            when :remote; self.pointed_to
            when :local;  self.points_to
            end

          target[association_data] =
            if association_data.shared
              build_update_for_single_referenced_association(association_data, association_hash, update_context)
            else
              build_update_for_single_association(association_data, association_hash, update_context)
            end
        end

      else
        raise "Unknown hash member #{k}" # TODO
      end
    end

    self.subtree_hash = nil

    self
  end

  private

  def build_update_for_single_referenced_association(association_data, child_ref_hash, update_context)
    # TODO intern loads for shared items so we only load them once

    if child_ref_hash.nil?
      nil
    else
      ActiveRecordViewModel::UpdateOperation.valid_reference_hash!(child_ref_hash)

      ref = child_ref_hash[ActiveRecordViewModel::REFERENCE_ATTRIBUTE]
      referred_update = update_context.resolve_reference(ref)

      unless association_data.accepts?(referred_update.viewmodel.class)
        raise ViewModel::DeserializationError.new("Association '#{association_data.reflection.name}' can't refer to #{referred_update.viewmodel.class}") # TODO
      end

      referred_update.build!(update_context)
    end
  end


  def build_update_for_single_association(association_data, child_hash, update_context)
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

    if child_hash.nil?
      child_update = nil
    else
      ActiveRecordViewModel::UpdateOperation.valid_subtree_hash!(child_hash)

      id        = child_hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
      type_name = child_hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)

      child_viewmodel_class = association_data.viewmodel_class_for_name(type_name)

      child_viewmodel =
        if id.nil?
          self.association_changed!
          child_viewmodel_class.new
        else
          key = ActiveRecordViewModel::ViewModelReference.new(child_viewmodel_class, id)
          case
          when taken_child_release_entry = update_context.try_take_released_viewmodel(key)
            self.association_changed!
            taken_child_release_entry.viewmodel
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
          reference = child_viewmodel
          update_context.defer_update(
            reference, update_context.new_explicit_update(nil, child_hash, reparent_to: parent_data, viewmodel_reference: reference))
        else
          update_context.new_explicit_update(child_viewmodel, child_hash, reparent_to: parent_data).build!(update_context)
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


  def build_updates_for_collection_association(association_data, child_hashes, update_context)
    model = self.viewmodel.model

    child_viewmodel_class = association_data.viewmodel_class

    # reference back to this model, so we can set the link while updating the children
    parent_data = ParentData.new(association_data.reflection.inverse_of, viewmodel)

    unless child_hashes.is_a?(Array)
      raise ViewModel::DeserializationError.new("Invalid hash data array for multiple association: '#{child_hashes.inspect}'")
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
    child_viewmodels = child_hashes.map do |child_hash|
      ActiveRecordViewModel::UpdateOperation.valid_subtree_hash!(child_hash)

      id        = child_hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
      type_name = child_hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)

      if type_name.nil?
        raise ViewModel::DeserializationError.new("Missing #{ActiveRecordViewModel::TYPE_ATTRIBUTE} deserializing #{child_viewmodel_class.name}")
      end

      # Check specified type: must match expected viewmodel class
      if association_data.viewmodel_class_for_name(type_name) != child_viewmodel_class
        raise "Inappropriate child type" #TODO
      end

      key = ActiveRecordViewModel::ViewModelReference.new(child_viewmodel_class, id)
      case
      when id.nil?
        self.association_changed!
        child_viewmodel_class.new
      when existing_child = previous_children.delete(id)
        child_viewmodel_class.new(existing_child)
      when taken_child_release_entry = update_context.try_take_released_viewmodel(key)
        self.association_changed!
        taken_child_release_entry.viewmodel
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
    child_updates = child_viewmodels.zip(child_hashes, positions).map do |child_viewmodel, child_hash, position|
      case child_viewmodel
      when ActiveRecordViewModel::ViewModelReference # deferred
        reference = child_viewmodel
        update_context.defer_update(
          reference, update_context.new_explicit_update(nil, child_hash, reparent_to: parent_data, reposition_to: position, viewmodel_reference: reference))
      else
        update_context.new_explicit_update(child_viewmodel, child_hash, reparent_to: parent_data, reposition_to: position).build!(update_context)
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
