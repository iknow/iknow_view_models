# Assembles an update operation tree from user input. Handles the interlinking
# and model of update operations, but does not handle the actual user data nor
# the mechanism by which it is applied to models.
class ActiveRecordViewModel::UpdateContext
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

  # TODO an unfortunate abstraction violation. The `append` case constructs an
  # update tree and later injects the context of parent and position.
  attr_reader :root_updates

  def initialize
    @root_updates       = [] # The subject(s) of this update
    @referenced_updates = {} # Shared data updates, referred to by a ref hash

    # hash of { ViewModelReference => :implicit || :explicit }; used to assert
    # only a single update is present for each viewmodel, and prevents conflicts
    # by explicit and implicit updates for the same model.
    @updates_by_viewmodel = {}

    # hash of { ViewModelReference => deferred UpdateOperation }
    # for linked partially-constructed node updates
    @worklist = {}

    # hash of { ViewModelReference => ReleaseEntry } for models
    # that have been released by nodes we've already visited
    @released_viewmodels = {}
  end

  # Loads corresponding viewmodels and constructs UpdateOperations for the
  # provided [[ref, viewmodel_class, id-or-nil, safe_root_subtree],...]
  def construct_updates(updates)
    # Look up viewmodel classes for each tree with eager_includes. Note this
    # won't yet include through a polymorphic boundary: for now we become
    # lazy-loading and slow every time that happens.
    roots_by_viewmodel_class = updates.group_by { |_, viewmodel_class, _, _| viewmodel_class }

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
        [ref, new_explicit_update(viewmodel, subtree_hash)]
      end
    end
  end

  private :construct_updates

  def self.new_update_tree(root_subtree_hashes, referenced_subtree_hashes, root_type: nil)
    self.new
      .build_root_updates(root_subtree_hashes, referenced_subtree_hashes, root_type: root_type)
      .assemble_update_tree!
  end

  # Processes root hashes and subtree hashes into @root_updates and @referenced_updates.
  def build_root_updates(root_subtree_hashes, referenced_subtree_hashes, root_type: nil)
    # Check input and build an array of [ref-or-nil, viewmodel_class, hash] for all subtrees
    proto_updates = root_subtree_hashes.map do |subtree_hash|
      viewmodel_class, id, safe_hash =
        ActiveRecordViewModel::UpdateOperation.extract_metadata_from_hash(subtree_hash)

      # Updates in the primary array may optionally be constrained to a particular type
      if root_type.present? && viewmodel_class != root_type
        raise ViewModel::DeserializationError.new("Cannot deserialize incorrect root viewmodel type '#{viewmodel_class.view_name}'")
      end

      [nil, viewmodel_class, id, safe_hash]
    end

    if referenced_subtree_hashes.present?
      references = referenced_subtree_hashes.map do |reference, subtree_hash|
        viewmodel_class, id, safe_hash =
          ActiveRecordViewModel::UpdateOperation.extract_metadata_from_hash(subtree_hash)

        raise "Invalid reference string: #{reference}" unless reference.is_a?(String)
        [reference, viewmodel_class, id, safe_hash]
      end

      proto_updates.concat(references)
    end

    # Ensure that no root is referred to more than once
    ref_counts = proto_updates.each_with_object(Hash.new(0)) do |(_, viewmodel_class, id, _), counts|
      counts[[viewmodel_class, id]] += 1 if id
    end.delete_if { |_, count| count == 1 }

    if ref_counts.present?
      raise ViewModel::DeserializationError.new("Duplicate entries in specification: '#{ref_counts.keys.to_h}'")
    end

    # construct [[ref-or-nil, update]]
    updates = construct_updates(proto_updates)

    # Separate out root and referenced updates
    updates.each do |ref, update|
      if ref.nil?
        @root_updates << update
      else
        # TODO make sure that referenced subtree hashes are unique and provide a decent error message
        # not strictly necessary, but will save confusion
        @referenced_updates[ref] = update
      end
    end

    self
  end

  # Applies updates and subsequently releases. Returns the updated viewmodels.
  def run!(view_context:)
    updated_viewmodels = @root_updates.map do |root_update|
      root_update.run!(view_context: view_context)
    end

    @released_viewmodels.each_value do |release_entry|
      release_entry.release!
    end

    updated_viewmodels
  end

  def assemble_update_tree!
    @root_updates.each do |root_update|
      root_update.build!(self)
    end

    while @worklist.present?
      key = @worklist.keys.detect { |k| @released_viewmodels.has_key?(k) }

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

        key, deferred_update = @worklist.detect { |k, upd| upd.reparent_to.present? }
        if key.nil?
          vms = @worklist.keys.map {|k| "#{k.viewmodel_class.view_name}:#{k.model_id}" }.join(", ")
          raise ViewModel::DeserializationError.new("Cannot resolve previous parents for the following referenced viewmodels: #{vms}")
        end

        # We are guaranteed to make progress or fail entirely.

        @worklist.delete(key)

        child_model = key.viewmodel_class.model_scope.find(key.model_id)  # TODO: model scope context
        child_viewmodel = key.viewmodel_class.new(child_model)
        deferred_update.viewmodel = child_viewmodel

        # We have progressed the item, but we must enforce the constraint that we can edit the parent.

        parent_assoc_name = deferred_update.reparent_to.association_reflection.name
        parent_viewmodel_class = deferred_update.reparent_to.viewmodel.class

        # This will create an update for the parent. Note that if we enter here
        # we may already have seen an explicit update to the parent, but this
        # case is always in error. If we didn't, we guarantee it won't exist
        # TODO how? by expanding all subtrees/releases first?.
        ensure_parent_edit_assertion_update(child_viewmodel, parent_viewmodel_class, parent_assoc_name)
      else
        deferred_update = @worklist.delete(key)
        deferred_update.viewmodel = @released_viewmodels.delete(key).viewmodel
      end

      deferred_update.build!(self)
    end

    @referenced_updates.each do |ref, upd|
      raise ViewModel::DeserializationError.new("Reference '#{ref}' was not referred to from roots") unless upd.built? # TODO
    end

    self
  end

  # When a child holds the pointer and has a parent that is not part of the
  # update tree, we create a dummy update that asserts we have the ability to
  # edit the parent. However, we only want to do this once for each parent.
  def ensure_parent_edit_assertion_update(child_viewmodel, parent_viewmodel_class, parent_association_name)
    assoc = child_viewmodel.model.association(parent_association_name)

    parent_model_id = child_viewmodel.model.send(
      child_viewmodel.model.association(parent_association_name).reflection.foreign_key)

    ref = ActiveRecordViewModel::ViewModelReference.new(
      parent_viewmodel_class, parent_model_id)

    return if @updates_by_viewmodel[ref] == :implicit

    old_parent_model     = assoc.klass.find(parent_model_id)
    old_parent_viewmodel = parent_viewmodel_class.new(old_parent_model)

    new_implicit_update(old_parent_viewmodel, {}).tap do |update|
      update.build!(self)
      update.association_changed!
      @root_updates << update
    end
  end

  ## Methods for objects being built in this context

  # We require the updates to be recorded in the context so we can enforce the
  # property that each viewmodel is in the tree at most once. To avoid mistakes,
  # we require construction to go via methods that do this tracking.

  def new_explicit_update(*args)
    update = ActiveRecordViewModel::UpdateOperation.new(*args)
    if (vm_ref = update.viewmodel_reference)
      set_update_type(vm_ref, :explicit)
    end
    update
  end

  def new_implicit_update(*args)
    update = ActiveRecordViewModel::UpdateOperation.new(*args)
    if (vm_ref = update.viewmodel_reference)
      set_update_type(vm_ref, :implicit)
    end
    update
  end

  def set_update_type(vm_ref, new_type)
    if (current_type = @updates_by_viewmodel[vm_ref]).nil?
      @updates_by_viewmodel[vm_ref] = new_type
    elsif current_type == :implicit && new_type == :implicit
      return
    else
      # explicit -> explicit; updating the same thing twice
      # implicit -> explicit; internal error, user update processed after implicit udpate
      # explicit -> implicit; trying to take something twice, once from user, then once again

      # TODO error messages
      raise "Not a valid type transition: #{current_type} -> #{new_type}"
    end
  end

  def resolve_reference(ref)
    @referenced_updates.fetch(ref) do
      raise ViewModel::DeserializationError.new("Could not find referenced data with key '#{ref}'")
    end
  end

  def try_take_released_viewmodel(vm_ref)
    @released_viewmodels.delete(vm_ref)
  end

  def release_viewmodel(viewmodel, association_data)
    @released_viewmodels[ActiveRecordViewModel::ViewModelReference.from_viewmodel(viewmodel)] =
      ReleaseEntry.new(viewmodel, association_data)
  end

  def defer_update(vm_ref, update_operation)
    @worklist[vm_ref] = update_operation
  end
end
