# Partially parsed tree of user-specified update hashes, created during deserialization.
class ActiveRecordViewModel::UpdateOperation
  # Key for deferred resolution of an AR model
  ViewModelReference = Struct.new(:viewmodel_class, :model_id) do
    class << self
      def from_view_model(vm)
        self.new(vm.class, vm.id)
      end
    end
  end

  # inverse association and record to update a change in parent from a child
  ParentData = Struct.new(:association_reflection, :model)

  attr_accessor :viewmodel,
                :attributes, # attr => serialized value
                :points_to,  # AssociationData => UpdateOperation (returns single new viewmodel to update fkey)
                :pointed_to, # AssociationData => UpdateOperation(s) (returns viewmodel(s) with which to update assoc cache)
                :reparent_to,  # If node needs to update its pointer to a new parent, ParentData for the parent
                :reposition_to, # if this node participates in a list under its parent, what should its position be?
                :deferred_subtree_hash # if this update hasn't been resolved to a viewmodel, the subtree hash to apply once resolved

  def initialize(viewmodel, reparent_to: nil, reposition_to: nil)
    self.viewmodel     = viewmodel
    self.attributes    = {}
    self.points_to     = {}
    self.pointed_to    = {}
    self.reparent_to   = reparent_to
    self.reposition_to = reposition_to
  end

  # divide up the hash into attributes and associations, and recursively
  # construct update trees for each association (either building new models or
  # associating them with loaded models). When a tree cannot be immediately
  # constructed because its model referent isn't loaded, put a stub in the
  # worklist.
  def self.construct_update_for_subtree(viewmodel, subtree_hash, worklist, released_viewmodels, reparent_to: nil, reposition_to: nil)
    update = self.new(viewmodel, reparent_to: reparent_to, reposition_to: reposition_to)
    update.process_subtree_hash(subtree_hash, worklist, released_viewmodels)
    update
  end

  def self.construct_deferred_update_for_subtree(subtree_hash, reparent_to: nil, reposition_to: nil)
    update = self.new(nil, reparent_to: reparent_to, reposition_to: reposition_to)
    update.deferred_subtree_hash = subtree_hash
    update
  end

  def deferred?
    viewmodel.nil?
  end

  # Once a deferred update can be associated with its viewmodel referent, continue
  # recursing into the subtree
  def resume_deferred_update(viewmodel, worklist, released_viewmodels)
    raise "bad state" unless deferred? # TODO

    subtree_hash = self.deferred_subtree_hash
    self.deferred_subtree_hash = nil
    self.viewmodel = viewmodel

    process_subtree_hash(subtree_hash, worklist, released_viewmodels)
    self
  end

  def run!(view_options)
    model = viewmodel.model

    debug_name = "#{model.class.name}:#{model.id}"
    debug "-> #{debug_name}: Entering"

    # TODO: editable! checks if this particular record is getting changed
    model.class.transaction do
      # update parent association
      if reparent_to.present?
        parent_name = reparent_to.association_reflection.name
        debug "-> #{debug_name}: Updating parent pointer to #{parent_name}:#{reparent_to.model.id}"
        association = model.association(parent_name)
        association.replace(reparent_to.model)
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
        viewmodel.public_send("deserialize_#{attr_name}", serialized_value, **view_options)
      end

      # Update points-to associations before save
      points_to.each do |association_data, child_operation|
        debug "-> #{debug_name}: Updating points-to association #{association_data.name}"

        association = model.association(association_data.name)
        child_model = if child_operation
                        child_operation.run!(view_options).model
                      else
                        nil
                      end
        association.replace(child_model)
        debug "<- #{debug_name}: Updated points-to association #{association_data.name}"
      end

      viewmodel.editable! if model.changed? # but what about our pointed-from children: if we release child, better own parent

      debug "-> #{debug_name}: Saving"
      model.save!
      debug "<- #{debug_name}: Saved"

      # Update association cache of pointed-from associations after save: the
      # child update will have saved the pointer.
      pointed_to.each do |association_data, child_operation|
        debug "-> #{debug_name}: Updating pointed-to association #{association_data.name}"

        association = model.association(association_data.name)

        new_target =
          case child_operation
          when nil
            nil
          when ActiveRecordViewModel::UpdateOperation
            child_operation.run!(view_options).model
          when Array
            viewmodels = child_operation.map { |op| op.run!(view_options) }
            viewmodels.map(&:model)
          end

        association.target = new_target

        debug "<- #{debug_name}: Updated pointed-to association #{association_data.name}"
      end
    end

    debug "<- #{debug_name}: Leaving"
    viewmodel
  end

  # Splits an update hash up into attributes, points-to associations and
  # pointed-to associations (in the context of our viewmodel), and recurses
  # into associations to create updates.
  def process_subtree_hash(subtree_hash, worklist, released_viewmodels)
    subtree_hash.each do |k, v|
      case  self.viewmodel.class._members[k]
      when :attribute
        attributes[k] = v

      when :association
        association_name = k
        association_hash = v

        association_data = self.viewmodel.class._association_data(association_name)

        if association_data.collection?
          self.pointed_to[association_data] = construct_updates_for_collection_association(association_data, association_hash, worklist, released_viewmodels)
        else
          target =
            case association_data.pointer_location
            when :remote; self.pointed_to
            when :local;  self.points_to
            end
          target[association_data] = construct_update_for_single_association(association_data, association_hash, worklist, released_viewmodels)
        end

      else
        raise "Unknown hash member #{k}" # TODO
      end
    end
  end

  private

  def construct_update_for_single_association(association_data, child_hash, worklist, released_viewmodels)
    model = self.viewmodel.model

    previous_child_model = model.public_send(association_data.name)

    if previous_child_model.present?
      previous_child_viewmodel_class = association_data.viewmodel_class_for_model(previous_child_model.class)
      previous_child_viewmodel = previous_child_viewmodel_class.new(previous_child_model)

      # Release the previous child if present: if the replacement hash refers to
      # it, it will immediately take it back.
      key = ViewModelReference.from_view_model(previous_child_viewmodel)
      released_viewmodels[key] = previous_child_viewmodel

      # Clear the cached association so that AR's save behaviour doesn't
      # conflict with our explicit parent updates. If we assign a new child (or
      # keep the same one), we'll come back with it and call
      # `Association#replace` in `run()`. If we don't, we promise that the child
      # will no longer be attached in the database, so the new cached data of
      # nil will be correct.
      model.association(association_data.name).target = nil
    end

    if child_hash.nil?
      nil
    elsif child_hash.is_a?(Hash)
      id        = child_hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
      type_name = child_hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)

      if type_name.nil?
        # TODO error at place in update hash
        raise ViewModel::DeserializationError.new("Missing #{ActiveRecordViewModel::TYPE_ATTRIBUTE} field in update hash")
      end

      child_viewmodel_class = association_data.viewmodel_class_for_name(type_name)

      child_viewmodel =
        case
        when id.nil?
          child_viewmodel_class.new
        when taken_child = released_viewmodels.delete(ViewModelReference.new(child_viewmodel_class, id))
          taken_child
        else
          # not-yet-seen child: create a deferred update
          nil
        end

      # if the association's pointer is in the child, need to provide it with a ParentData to update
      parent_data =
        if association_data.pointer_location == :remote
          ParentData.new(association_data.reflection.inverse_of, model)
        else
          nil
        end

      child_update =
        if child_viewmodel.nil?
          key = ViewModelReference.new(child_viewmodel_class, id)
          deferred_update = ActiveRecordViewModel::UpdateOperation.construct_deferred_update_for_subtree(child_hash, reparent_to: parent_data)
          worklist[key] = deferred_update
          deferred_update
        else
          ActiveRecordViewModel::UpdateOperation.construct_update_for_subtree(child_viewmodel, child_hash, worklist, released_viewmodels, reparent_to: parent_data)
        end

      child_update
    else
      raise ViewModel::DeserializationError.new("Invalid hash data for single association: '#{child_hash.inspect}'")
    end
  end

  def construct_updates_for_collection_association(association_data, child_hashes, worklist, released_viewmodels)
    model = self.viewmodel.model

    child_viewmodel_class = association_data.viewmodel_class
    child_model_class = child_viewmodel_class.model_class

    # reference back to this model, so we can set the link while updating the children
    parent_data = ParentData.new(association_data.reflection.inverse_of, model)

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
      # previous children will have had their parent pointers updated.
      model.association(association_data.name).target = []
    end

    # Construct viewmodels for incoming hash data. Where a child hash references
    # an existing model not currently attached to this parent, it must be found
    # before recursing into that child. If the model is available in released
    # models we can recurse into them, otherwise we must attach a stub
    # UpdateOperation (and add it to the worklist to process later)
    child_viewmodels = child_hashes.map do |child_hash|
      id        = child_hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
      type_name = child_hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)

      if type_name.nil?
        raise ViewModel::DeserializationError.new("Missing #{ActiveRecordViewModel::TYPE_ATTRIBUTE} deserializing #{child_viewmodel_class.name}")
      end

      # Check specified type: must match expected viewmodel class
      if association_data.viewmodel_class_for_name(type_name) != child_viewmodel_class
        raise "Inappropriate child type" #TODO
      end

      case
      when id.nil?
        child_viewmodel_class.new
      when existing_child = previous_children.delete(id)
        child_viewmodel_class.new(existing_child)
      when taken_child_viewmodel = released_viewmodels.delete(ViewModelReference.new(child_viewmodel_class, id))
        taken_child_viewmodel
      else
        # Refers to child that hasn't yet been seen: create a deferred update.
        nil
      end
    end

    # release previously attached children that are no longer referred to
    previous_children.each_value do |model|
      viewmodel = child_viewmodel_class.new(model)
      key = ViewModelReference.from_view_model(viewmodel)
      released_viewmodels[key] = viewmodel
    end

    # calculate new positions for children if in a list
    positions = Array.new(child_viewmodels.length)
    if child_viewmodel_class._list_member?
      get_position = ->(index){ child_viewmodels[index].try(&:_list_attribute) }
      set_position = ->(index, pos){ positions[index] = pos }

      ActsAsManualList.update_positions((0...child_viewmodels.size), # indexes
                                        position_getter: get_position,
                                        position_setter: set_position)
    end

    # Recursively build update operations for children
    child_updates = child_viewmodels.zip(child_hashes, positions).map do |child_viewmodel, child_hash, position|
      if child_viewmodel.nil?
        key = ViewModelReference.new(child_viewmodel_class, hash[ActiveRecordViewModel::ID_ATTRIBUTE])
        deferred_update = ActiveRecordViewModel::UpdateOperation.construct_deferred_update_for_subtree(child_hash, reparent_to: parent_data, reposition_to: position)
        worklist[key] = deferred_update
        deferred_update
      else
        ActiveRecordViewModel::UpdateOperation.construct_update_for_subtree(child_viewmodel, child_hash, worklist, released_viewmodels, reparent_to: parent_data, reposition_to: position)
      end
    end

    child_updates
  end

  def print(prefix = nil)
    puts "#{prefix}#{self.class.name} #{model.class.name}(id=#{model.id || 'new'})"
    prefix = "#{prefix}  "
    attributes.each do |attr, value|
      puts "#{prefix}#{attr}=#{value}"
    end
    points_to.each do |name, value|
      puts "#{prefix}#{name} = "
      value.print("#{prefix}  ")
    end
    pointed_to.each do |name, value|
      puts "#{prefix}#{name} = "
      value.print("#{prefix}  ")
    end
  end

  def debug(msg)
    ActiveRecord::Base.logger.try do |logger|
      logger.debug(msg)
    end
  end

end
