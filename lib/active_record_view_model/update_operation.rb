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
  ParentData = Struct.new(:association_reflection, :viewmodel)

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
    @association_changed = false
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

  class << self
    # Determines user intent from a hash, extracting identity metadata and
    # returning a tuple of viewmodel_class, id, and a pure-data hash. The input
    # hash will be consumed.
    def extract_metadata_from_hash(hash)
      valid_subtree_hash!(hash)

      unless hash.has_key?(ActiveRecordViewModel::TYPE_ATTRIBUTE)
        raise ViewModel::DeserializationError.new("Missing '#{ActiveRecordViewModel::TYPE_ATTRIBUTE}' field in update hash: '#{hash.inspect}'")
      end

      id        = hash.delete(ActiveRecordViewModel::ID_ATTRIBUTE)
      type_name = hash.delete(ActiveRecordViewModel::TYPE_ATTRIBUTE)

      viewmodel_class = ActiveRecordViewModel.for_view_name(type_name)

      return viewmodel_class, id, hash
    end

    def build_updates(root_subtree_hashes, referenced_subtree_hashes, root_type: nil)
      # Check input and build an array of [ref-or-nil, viewmodel_class, hash] for all subtrees
      roots = root_subtree_hashes.map do |subtree_hash|
        viewmodel_class, id, safe_hash = extract_metadata_from_hash(subtree_hash)

        # Updates in the primary array may optionally be constrained to a particular type
        if root_type.present? && viewmodel_class != root_type
          raise ViewModel::DeserializationError.new("Cannot deserialize incorrect root viewmodel type '#{viewmodel_class.view_name}'")
        end

        [nil, viewmodel_class, id, safe_hash]
      end

      references = referenced_subtree_hashes.map do |reference, subtree_hash|
        viewmodel_class, id, safe_hash = extract_metadata_from_hash(subtree_hash)

        raise "Invalid reference string: #{reference}" unless reference.is_a?(String)
        [reference, viewmodel_class, id, safe_hash]
      end

      roots.concat(references)

      # Ensure that no root is referred to more than once
      ref_counts = roots.each_with_object(Hash.new(0)) do |(_, viewmodel_class, id, _), counts|
        counts[[viewmodel_class, id]] += 1
      end.delete_if { |_, count| count > 1 }

      if ref_counts.present?
        raise ViewModel::DeserializationError.new("Duplicate entries in specification: '#{ref_counts.keys.to_h}'")
      end

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
        key = worklist.keys.detect { |k| released_viewmodels.has_key?(k) }

        if key.nil?
          # All worklist viewmodels are unresolvable from roots. We need to
          # manually load unresolvable VMs, and additionally add their previous
          # parents (if present) as otherwise-unmodified roots with
          # `association_changed!` set, in order that we can correctly
          # `editable?` check them.

          # So we can't quite do this yet: having put the deferred update on the
          # worklist, we've discarded how we got to it. This means we don't
          # currently have a way to know what inverse association to load the
          # parent from.

          # OH! not true! because the `UpdateOperation` that's on the worklist
          # will (if the foreign key is from child to parent) have a parent_data
          # set, which will include the reflection inverse and viewmodel. We can
          # use that information to load the previous parent.

          # if the foreign key is from the parent to the child however, it's a
          # little bit less safe. Even if we have the inverse relationship
          # recorded, if multiple other viewmodels are allowed to point into the
          # child (but only one at a time!) there's no way to safely move in all
          # conditions. One option would be to _try_ the inverse relationship:
          # if the inverse relationship resolves into a parent to move from, we
          # know it's safe to move (assuming the single-pointer invariant
          # previously held). If it doesn't though, we have no way of knowing if
          # it's actually unparented or if it's merely referred to from a third
          # party, so we are required to forbid the update.

          # Note that this would require slightly more code plumbing to achieve,
          # because we'd need to update the pointer in the old parent (versus only
          # in the child itself).

          # Additionally we need to forbid specifying the same out-of-tree
          # viewmodel twice. Otherwise we would correctly transfer from the old
          # parent, but then subsequently destroy the first transfer when
          # performing the second.

          key, deferred_update = worklist.detect { |k, upd| upd.reparent_to.present? }
          if key.nil?
            vms = worklist.keys.map {|k| "#{k.viewmodel_class.view_name}:#{k.model_id}" }.join(", ")
            raise ViewModel::DeserializationError.new("Cannot resolve previous parents for the following referenced viewmodels: #{vms}")
          end

          worklist.delete(key)

          viewmodel = key.viewmodel_class.model_scope.find(key.model_id) # TODO: model scope context
          deferred_update.viewmodel = viewmodel

          # find old parent, mark it as updated and add it as a root.
          parent_assoc_name = deferred_update.reparent_to.association_reflection.name
          parent_viewmodel_class = deferred_update.reparent_to.viewmodel.class

          # TODO: avoid loading parent via the association directly: this will set up association caches that AR could use to reverse the updates.
          old_parent = viewmodel.association(parent_assoc_name).load_target

          old_parent_update = UpdateOperation.new(parent_viewmodel_class.new(old_parent), {})
          old_parent_update.association_changed!
          root_updates << old_parent_update
        else
          deferred_update = worklist.delete(key)
          deferred_update.viewmodel = released_viewmodels.delete(key).viewmodel
        end

        deferred_update.build!(worklist, released_viewmodels, referenced_updates)
      end

      referenced_updates.each do |ref, upd|
        raise ViewModel::DeserializationError.new("Reference '#{ref}' was not referred to from roots") unless upd.built? # TODO
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
    # provided [[ref, viewmodel_class, id-or-nil, safe_root_subtree],...]
    def construct_root_updates(roots)
      # Look up viewmodel classes for each tree with eager_includes. Note this
      # won't yet include through a polymorphic boundary: for now we become
      # lazy-loading and slow every time that happens.
      roots_by_viewmodel_class = roots.group_by { |_, viewmodel_class, _, _| viewmodel_class }

      # For each viewmodel type, look up referenced models and construct viewmodels to update
      roots_by_viewmodel_class.flat_map do |viewmodel_class, viewmodel_roots|
        model_ids = viewmodel_roots.map { |_, _, id, _| id }.compact

        existing_models = if model_ids.present?
                            #TODO: using model scope without providing the context means we'll potentially over-eager-load
                            viewmodel_class.model_scope.find_all!(model_ids).index_by(&:id)
                          else
                            {}
                          end

        viewmodel_roots.map do |ref, viewmodel_class, id, subtree_hash|
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
        raise ViewModel::DeserializationError.new("Association '#{association_data.reflection.name}' can't refer to #{referred_update.viewmodel.class}") # TODO
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
      previous_child_key = ViewModelReference.from_viewmodel(previous_child_viewmodel)

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
          key = ViewModelReference.new(child_viewmodel_class, id)
          case
          when taken_child_release_entry = released_viewmodels.delete(key)
            self.association_changed!
            taken_child_release_entry.viewmodel
          when key == previous_child_key
            previous_child_key = nil
            previous_child_viewmodel
          else
            # not-yet-seen child: create a deferred update
            self.association_changed!
            ViewModelReference.new(child_viewmodel_class, id)
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
        when ViewModelReference # deferred
          reference = child_viewmodel
          worklist[reference] = ActiveRecordViewModel::UpdateOperation.new(nil, child_hash, reparent_to: parent_data)
        else
          ActiveRecordViewModel::UpdateOperation.new(child_viewmodel, child_hash, reparent_to: parent_data).build!(worklist, released_viewmodels, referenced_updates)
        end
    end

    # Release the previous child if not reclaimed
    if previous_child_key.present?
      self.association_changed!
      # When we free a child that's pointed to from its old parent, we need to
      # clear the cached association to that old parent. If we don't do this,
      # then if the child gets claimed by a new parent and `save!`ed, AR will
      # re-establish the link from the old parent in the cache.
      if association_data.pointer_location = :local && association_data.reflection.inverse_of.present?
        clear_association_cache(previous_child_model, association_data.reflection.inverse_of)
      end
      released_viewmodels[previous_child_key] = ReleaseEntry.new(previous_child_viewmodel, association_data)
    end

    child_update
  end


  def build_updates_for_collection_association(association_data, child_hashes, worklist, released_viewmodels, referenced_updates)
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

      case
      when id.nil?
        self.association_changed!
        child_viewmodel_class.new
      when existing_child = previous_children.delete(id)
        child_viewmodel_class.new(existing_child)
      when taken_child_release_entry = released_viewmodels.delete(ViewModelReference.new(child_viewmodel_class, id))
        self.association_changed!
        taken_child_release_entry.viewmodel
      else
        # Refers to child that hasn't yet been seen: create a deferred update.
        self.association_changed!
        ViewModelReference.new(child_viewmodel_class, id)
      end
    end

    # release previously attached children that are no longer referred to
    previous_children.each_value do |child_model|
      self.association_changed!
      child_viewmodel = child_viewmodel_class.new(child_model)
      key = ViewModelReference.from_viewmodel(child_viewmodel)
      released_viewmodels[key] = ReleaseEntry.new(child_viewmodel, association_data)
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

  def clear_association_cache(model, reflection)
    association = model.association(reflection.name)
    if reflection.collection?
      association.target = []
    else
      association.target = nil
    end
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
