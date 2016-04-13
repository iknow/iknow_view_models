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

  SharedReferences = Struct.new(:shared_subtrees, :shared_updates) do
    def initialize(shared_subtrees)
      super(shared_subtrees, {})
    end

    def resolve(ref)
      shared_updates[ref] ||= create_update(ref)
    end

    private

    def create_update(ref)
      subtree = shared_subtrees[ref]
      if subtree.nil?
        raise "TODO"
      end
      # woop a viewmodel. Heeeey this is all the code from our left hand side yo
      updates, released_viewmodels = UpdateOperation.construct_updates_for_trees(subtree)
      # So probably we want to build a plan of updates first and then run
      # (ensuring that any shared update that's hit twice still runs only
      # once). So going to have to abstract most of the contents of the
      # deserialize_from_view.
    end
  end

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

  class << self
    def construct_updates_for_trees(tree_hashes)
      # Check we've been passed sane typed data
      tree_hashes.each do |tree_hash|
        unless tree_hash.is_a?(Hash)
          raise ViewModel::DeserializationError.new("Invalid viewmodel tree to deserialize: '#{tree_hash.inspect}'")
        end
      end

      # Look up viewmodel classes for each tree
      # with eager_includes: note this won't yet include through a polymorphic boundary, so we go lazy and slow every time that happens.
      tree_hashes_by_viewmodel_class = tree_hashes.group_by do |tree_hash|
        unless tree_hash.has_key?(ActiveRecordViewModel::TYPE_ATTRIBUTE)
          raise ViewModel::DeserializationError.new("Missing '#{ActiveRecordViewModel::TYPE_ATTRIBUTE}' field in update hash: '#{tree_hash.inspect}'")
        end

        type_name = tree_hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)
        ActiveRecordViewModel.for_view_name(type_name)
      end

      # For each viewmodel type, look up referenced models and construct viewmodels to update
      update_roots = []
      tree_hashes_by_viewmodel_class.each do |viewmodel_class, tree_hashes|
        model_ids = tree_hashes.map { |h| h[ActiveRecordViewModel::ID_ATTRIBUTE] }.compact
        existing_models = viewmodel_class.model_scope.find_all!(model_ids).index_by(&:id)

        tree_hashes.each do |tree_hash|
          id = tree_hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
          viewmodel =
            if id.present?
              viewmodel_class.new(existing_models[id])
            else
              viewmodel_class.new
            end
          update_roots << [viewmodel, tree_hash]
        end
      end

      # Build update operations

      # hash of { UpdateOperation::ViewModelReference => deferred UpdateOperation }
      # for linked partially-constructed node updates
      worklist = {}

      # hash of { UpdateOperation::ViewModelReference => ReleaseEntry } for models
      # that have been released by nodes we've already visited
      released_viewmodels = {}

      root_updates = update_roots.map do |root_viewmodel, tree_hash|
        construct_update_for_subtree(root_viewmodel, tree_hash, worklist, released_viewmodels)
      end

      while worklist.present?
        key = worklist.keys.detect { |key| released_viewmodels.has_key?(key) }
        raise "Can't match a released viewmodel for any deferred updates in worklist: #{worklist.inspect}" if key.nil?

        deferred_update = worklist.delete(key)
        viewmodel = released_viewmodels.delete(key).viewmodel
        deferred_update.resume_deferred_update(viewmodel, worklist, released_viewmodels)
      end

      return root_updates, released_viewmodels
    end

    # TODO internal, but not private since we have ref from class->instance
    # private

    # divide up the hash into attributes and associations, and recursively
    # construct update trees for each association (either building new models or
    # associating them with loaded models). When a tree cannot be immediately
    # constructed because its model referent isn't loaded, put a stub in the
    # worklist.
    def construct_update_for_subtree(viewmodel, subtree_hash, worklist, released_viewmodels, reparent_to: nil, reposition_to: nil)
      update = self.new(viewmodel, reparent_to: reparent_to, reposition_to: reposition_to)
      update.process_subtree_hash(subtree_hash, worklist, released_viewmodels)
      update
    end

    def construct_deferred_update_for_subtree(subtree_hash, reparent_to: nil, reposition_to: nil)
      update = self.new(nil, reparent_to: reparent_to, reposition_to: reposition_to)
      update.deferred_subtree_hash = subtree_hash
      update
    end

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

  def run!(view_context:)
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

          target[association_data] =
            if association_data.shared
              construct_update_for_single_referenced_association(association_data, association_hash)
            else
              construct_update_for_single_association(association_data, association_hash, worklist, released_viewmodels)
            end
        end

      else
        raise "Unknown hash member #{k}" # TODO
      end
    end
  end

  private

  def construct_update_for_single_referenced_association(association_data, child_ref_hash)
    # TODO intern loads for shared items so we only load them once

    if child_ref_hash.nil?
      nil
    elsif child_ref_hash.is_a?(Hash)
      id        = child_ref_hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
      type_name = child_ref_hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)

      # A reference specifies a target model and no updates
      unless child_ref_hash.empty?
        raise ViewModel::DeserializationError.new("Child hash is not a reference, found additional keys #{child_ref_hash.keys.inspect}")
      end

      referred_model = association_data.viewmodel_class_for_name(type_name).find(id)

      # TODO use a "ReferenceOperation" type or assert that an empty UpdateOperation#run! will never modify?
      ActiveRecordViewModel::ReferenceOperation.new(referred_model)
    else
      raise ViewModel::DeserializationError.new("Invalid hash data for shared association: '#{child_hash.inspect}'")
    end
  end

  def construct_update_for_single_association(association_data, child_hash, worklist, released_viewmodels)
    model = self.viewmodel.model

    previous_child_model = model.public_send(association_data.name)

    if previous_child_model.present?
      previous_child_viewmodel_class = association_data.viewmodel_class_for_model(previous_child_model.class)
      previous_child_viewmodel = previous_child_viewmodel_class.new(previous_child_model)

      # Release the previous child if present: if the replacement hash refers to
      # it, it will immediately take it back.
      key = ViewModelReference.from_view_model(previous_child_viewmodel)
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
          worklist[reference] = ActiveRecordViewModel::UpdateOperation.construct_deferred_update_for_subtree(child_hash, reparent_to: parent_data)
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
      key = ViewModelReference.from_view_model(viewmodel)
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
        worklist[reference] = ActiveRecordViewModel::UpdateOperation.construct_deferred_update_for_subtree(child_hash, reparent_to: parent_data, reposition_to: position)
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
