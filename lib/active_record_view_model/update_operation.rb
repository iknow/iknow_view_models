require "renum"

# Partially parsed tree of user-specified update hashes, created during deserialization.
class ActiveRecordViewModel::UpdateOperation
  # Key for deferred resolution of an AR model
  ViewModelReference = Struct.new(:viewmodel_class, :model_id) do
    class << self
      def from_viewmodel(vm)
        self.new(vm.class, vm.id)
      end
    end
  end

  ReleaseEntry = Struct.new(:viewmodel, :association_data) do
    def release!
      model = viewmodel.model
      case association_data.reflection.options[:dependent]
      when :delete
        model.delete
      when :destroy
        model.destroy
      end
    end
  end

  # inverse association and record to update a change in parent from a child
  ParentData = Struct.new(:association_reflection, :model)

  enum :RunState, [:Pending, :Running, :Run]

  attr_accessor :viewmodel,
                :subtree_hash,
                :attributes, # attr => serialized value
                :points_to,  # AssociationData => UpdateOperation (returns single new viewmodel to update fkey)
                :pointed_to, # AssociationData => UpdateOperation(s) (returns viewmodel(s) with which to update assoc cache)
                :reparent_to,  # If node needs to update its pointer to a new parent, ParentData for the parent
                :reposition_to # if this node participates in a list under its parent, what should its position be?

  def initialize(viewmodel, subtree_hash, reparent_to: nil, reposition_to: nil)
    self.viewmodel     = viewmodel
    self.subtree_hash  = subtree_hash
    self.attributes    = {}
    self.points_to     = {}
    self.pointed_to    = {}
    self.reparent_to   = reparent_to
    self.reposition_to = reposition_to

    @run_state = RunState::Pending
  end

  def deferred?
    viewmodel.nil?
  end

  def built?
    subtree_hash.nil?
  end

  class << self
    def build_updates(root_subtree_hashes, referenced_subtree_hashes)
      # Check input and build an array of [ref-or-nil, hash] for all subtrees
      roots = root_subtree_hashes.map do |subtree_hash|
        valid_subtree_hash!(subtree_hash)
        [nil, subtree_hash]
      end

      roots.concat(referenced_subtree_hashes.map do |reference, subtree_hash|
        valid_subtree_hash!(subtree_hash)
        raise "Invalid reference string: #{reference}" unless reference.is_a?(String)
        [reference, subtree_hash]
      end)

      # construct [[ref-or-nil, update]]
      all_root_updates = construct_root_updates(roots)

      # Separate out root and referenced updates
      root_updates       = []
      referenced_updates = {}
      all_root_updates.each do |ref, subtree_hash|
        if ref.nil?
          root_updates << subtree_hash
        else
          # TODO make sure that referenced subtree hashes are unique and provide a decent error message
          # not strictly necessary, but will save confusion
          referenced_updates[ref] = subtree_hash
        end
      end

      # Build root updates

      # hash of { UpdateOperation::ViewModelReference => deferred UpdateOperation }
      # for linked partially-constructed node updates
      worklist = {}

      # hash of { UpdateOperation::ViewModelReference => ReleaseEntry } for models
      # that have been released by nodes we've already visited
      released_viewmodels = {}

      root_updates.each do |root_update|
        root_update.build!(worklist, released_viewmodels, referenced_updates)
      end

      while worklist.present?
        key = worklist.keys.detect { |key| released_viewmodels.has_key?(key) }
        raise "Can't match a released viewmodel for any deferred updates in worklist: #{worklist.inspect}" if key.nil?

        deferred_update = worklist.delete(key)
        deferred_update.viewmodel = released_viewmodels.delete(key).viewmodel
        deferred_update.build!(worklist, released_viewmodels, referenced_updates)
      end

      referenced_updates.each do |ref, update|
        raise "Reference #{ref} was not referred to from roots" unless update.built? # TODO
      end

      return root_updates, released_viewmodels
    end

    def valid_subtree_hash!(subtree_hash)
      unless subtree_hash.is_a?(Hash)
        raise ViewModel::DeserializationError.new("Invalid data to deserialize - not a hash: '#{subtree_hash.inspect}'")
      end
      unless subtree_hash.has_key?(ActiveRecordViewModel::TYPE_ATTRIBUTE)
        raise ViewModel::DeserializationError.new("Invalid update hash data - '#{ActiveRecordViewModel::TYPE_ATTRIBUTE}' attribute missing: #{subtree_hash.inspect}")
      end
    end

    def valid_reference_hash!(subtree_hash)
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

    private

    # Loads corresponding viewmodels and constructs UpdateOperations for the
    # provided root subtrees. Subtrees are provided and returned in a map keyed
    # by opaque references.
    def construct_root_updates(roots)
      # Look up viewmodel classes for each tree with eager_includes. Note this
      # won't yet include through a polymorphic boundary: for now we become
      # lazy-loading and slow every time that happens.
      roots_by_viewmodel_class = roots.group_by do |ref, subtree_hash|
        unless subtree_hash.has_key?(ActiveRecordViewModel::TYPE_ATTRIBUTE)
          raise ViewModel::DeserializationError.new("Missing '#{ActiveRecordViewModel::TYPE_ATTRIBUTE}' field in update hash: '#{subtree_hash.inspect}'")
        end

        type_name = subtree_hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)
        ActiveRecordViewModel.for_view_name(type_name)
      end

      # For each viewmodel type, look up referenced models and construct viewmodels to update
      roots_by_viewmodel_class.flat_map do |viewmodel_class, roots|
        model_ids = roots.map { |_, hash| hash[ActiveRecordViewModel::ID_ATTRIBUTE] }.compact

        existing_models = viewmodel_class.model_scope.find_all!(model_ids).index_by(&:id)

        roots.map do |ref, subtree_hash|
          id = subtree_hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
          viewmodel =
            if id.present?
              viewmodel_class.new(existing_models[id])
            else
              viewmodel_class.new
            end
          [ref, ActiveRecordViewModel::UpdateOperation.new(viewmodel, subtree_hash)]
        end
      end
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

    # TODO: editable! checks if this particular record is getting changed
    model.class.transaction do
      # update parent association
      if reparent_to.present?
        debug "-> #{debug_name}: Updating parent pointer to '#{reparent_to.model.class.name}:#{reparent_to.model.id}'"
        association = model.association(reparent_to.association_reflection.name)
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

      viewmodel.editable!(view_context: view_context) if model.changed? # but what about our pointed-from children: if we release child, better own parent

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
  def build!(worklist, released_viewmodels, referenced_updates)
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
          self.pointed_to[association_data] = build_updates_for_collection_association(association_data, association_hash, worklist, released_viewmodels, referenced_updates)
        else
          target =
            case association_data.pointer_location
            when :remote; self.pointed_to
            when :local;  self.points_to
            end

          target[association_data] =
            if association_data.shared
              build_update_for_single_referenced_association(association_data, association_hash, worklist, released_viewmodels, referenced_updates)
            else
              build_update_for_single_association(association_data, association_hash, worklist, released_viewmodels, referenced_updates)
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

  def build_update_for_single_referenced_association(association_data, child_ref_hash, worklist, released_viewmodels, referenced_updates)
    # TODO intern loads for shared items so we only load them once

    if child_ref_hash.nil?
      nil
    else
      ActiveRecordViewModel::UpdateOperation.valid_reference_hash!(child_ref_hash)

      ref = child_ref_hash[ActiveRecordViewModel::REFERENCE_ATTRIBUTE]

      referred_update = referenced_updates[ref]

      unless referred_update.present?
        raise ViewModel::DeserializationError.new("Could not find referenced data with key '#{ref}'")
      end

      unless association_data.accepts?(referred_update.viewmodel.class)
        raise ViewModel::DeserializationError.new("Association '#{association.reflection.name}' can't refer to #{referred_update.viewmodel.class}") # TODO
      end

      referred_update.build!(worklist, released_viewmodels, referenced_updates)
    end
  end

  def build_update_for_single_association(association_data, child_hash, worklist, released_viewmodels, referenced_updates)
    model = self.viewmodel.model

    previous_child_model = model.public_send(association_data.name)

    if previous_child_model.present?
      previous_child_viewmodel_class = association_data.viewmodel_class_for_model(previous_child_model.class)
      previous_child_viewmodel = previous_child_viewmodel_class.new(previous_child_model)

      # Release the previous child if present: if the replacement hash refers to
      # it, it will immediately take it back.
      key = ViewModelReference.from_viewmodel(previous_child_viewmodel)
      released_viewmodels[key] = ReleaseEntry.new(previous_child_viewmodel, association_data)

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
    else
      ActiveRecordViewModel::UpdateOperation.valid_subtree_hash!(child_hash)

      id        = child_hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
      type_name = child_hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)

      child_viewmodel_class = association_data.viewmodel_class_for_name(type_name)

      child_viewmodel =
        case
        when id.nil?
          child_viewmodel_class.new
        when taken_child_release_entry = released_viewmodels.delete(ViewModelReference.new(child_viewmodel_class, id))
          taken_child_release_entry.viewmodel
        else
          # not-yet-seen child: create a deferred update
          ViewModelReference.new(child_viewmodel_class, id)
        end

      # if the association's pointer is in the child, need to provide it with a ParentData to update
      parent_data =
        if association_data.pointer_location == :remote
          ParentData.new(association_data.reflection.inverse_of, model)
        else
          nil
        end

      child_update =
        case child_viewmodel
        when ViewModelReference # deferred
          reference = child_viewmodel
          worklist[reference] = ActiveRecordViewModel::UpdateOperation.new(nil, child_hash, reparent_to: parent_data)
        else
          ActiveRecordViewModel::UpdateOperation.new(child_viewmodel, child_hash, reparent_to: parent_data).build!(worklist, released_viewmodels, referenced_updates)
        end

      child_update
    end
  end

  def build_updates_for_collection_association(association_data, child_hashes, worklist, released_viewmodels, referenced_updates)
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

      case
      when id.nil?
        child_viewmodel_class.new
      when existing_child = previous_children.delete(id)
        child_viewmodel_class.new(existing_child)
      when taken_child_release_entry = released_viewmodels.delete(ViewModelReference.new(child_viewmodel_class, id))
        taken_child_release_entry.viewmodel
      else
        # Refers to child that hasn't yet been seen: create a deferred update.
        ViewModelReference.new(child_viewmodel_class, id)
      end
    end

    # release previously attached children that are no longer referred to
    previous_children.each_value do |model|
      viewmodel = child_viewmodel_class.new(model)
      key = ViewModelReference.from_viewmodel(viewmodel)
      released_viewmodels[key] = ReleaseEntry.new(viewmodel, association_data)
    end

    # Calculate new positions for children if in a list. Ignore previous
    # positions for unresolved references: they'll always need to be updated
    # anyway since their parent pointer will change.
    positions = Array.new(child_viewmodels.length)
    if child_viewmodel_class._list_member?
      set_position = ->(index, pos){ positions[index] = pos }
      get_previous_position = ->(index) do
        vm = child_viewmodels[index]
        vm._list_attribute unless vm.is_a?(ViewModelReference)
      end

      ActsAsManualList.update_positions((0...child_viewmodels.size).to_a, # indexes
                                        position_getter: get_previous_position,
                                        position_setter: set_position)
    end

    # Recursively build update operations for children
    child_updates = child_viewmodels.zip(child_hashes, positions).map do |child_viewmodel, child_hash, position|
      case child_viewmodel
      when ViewModelReference # deferred
        reference = child_viewmodel
        worklist[reference] = ActiveRecordViewModel::UpdateOperation.new(nil, child_hash, reparent_to: parent_data, reposition_to: position)
      else
        ActiveRecordViewModel::UpdateOperation.new(child_viewmodel, child_hash, reparent_to: parent_data, reposition_to: position).build!(worklist, released_viewmodels, referenced_updates)
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
