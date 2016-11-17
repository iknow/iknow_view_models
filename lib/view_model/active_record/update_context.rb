# Assembles an update operation tree from user input. Handles the interlinking
# and model of update operations, but does not handle the actual user data nor
# the mechanism by which it is applied to models.
class ViewModel::ActiveRecord
  class UpdateContext
    ReleaseEntry = Struct.new(:viewmodel, :association_data) do
      def release!(deserialize_context:)
        model = viewmodel.model
        case association_data.direct_reflection.options[:dependent]
        when :delete
          viewmodel.editable!(deserialize_context: deserialize_context, deleted: true)
          model.delete
        when :destroy
          viewmodel.editable!(deserialize_context: deserialize_context, deleted: true)
          model.destroy
        end
      end
    end

    class ReleasePool
      def initialize
        # hash of { ViewModel::Reference => ReleaseEntry } for models
        # that have been released by nodes we've already visited
        @released_viewmodels = {}
      end

      def include?(key)
        @released_viewmodels.has_key?(key)
      end

      def release_to_pool(viewmodel, association_data)
        @released_viewmodels[viewmodel.to_reference] =
          ReleaseEntry.new(viewmodel, association_data)
      end

      def claim_from_pool(key)
        @released_viewmodels.delete(key)
      end

      def release_all!(deserialize_context)
        @released_viewmodels.each_value do |release_entry|
          release_entry.release!(deserialize_context: deserialize_context)
        end
      end
    end

    def self.build!(root_update_data, referenced_update_data, root_type: nil)
      if root_type.present? && (bad_types = root_update_data.map(&:viewmodel_class).to_set.delete(root_type)).present?
        raise ViewModel::DeserializationError.new(
                "Cannot deserialize incorrect root viewmodel type(s) '#{bad_types.map(&:view_name)}'",
                bad_types.map { |t| ViewModel::Reference.new(t, nil) })
      end

      self.new
        .build_root_update_operations(root_update_data, referenced_update_data)
        .assemble_update_tree
    end

    # TODO an unfortunate abstraction violation. The `append` case constructs an
    # update tree and later injects the context of parent and position.
    def root_updates
      @root_update_operations
    end

    def initialize
      @root_update_operations       = [] # The subject(s) of this update
      @referenced_update_operations = {} # Shared data updates, referred to by a ref hash

      # hash of { ViewModel::Reference => :implicit || :explicit }; used to assert
      # only a single update is present for each viewmodel, and prevents conflicts
      # by explicit and implicit updates for the same model.
      @updates_by_viewmodel = {}

      # hash of { ViewModel::Reference => deferred UpdateOperation }
      # for linked partially-constructed node updates
      @worklist = {}

      @release_pool = ReleasePool.new
    end

    # Processes parsed (UpdateData) root updates and referenced updates into
    # @root_update_operations and @referenced_update_operations.
    def build_root_update_operations(root_updates, referenced_updates)
      # Store a reference to the update data for references so we can load
      # models with appropriate preloading.
      @referenced_update_data = referenced_updates

      # Look up viewmodel classes for each tree with eager_includes. Note this
      # won't yet include through a polymorphic boundary: for now we become
      # lazy-loading and slow every time that happens.

      # Combine our root and referenced updates, and separate by viewmodel type
      updates_by_viewmodel_class =
        root_updates.lazily
          .map { |root_update| [nil, root_update] }
          .concat(referenced_updates)
          .group_by { |_, update_data| update_data.viewmodel_class }

      # For each viewmodel type, look up referenced models and construct viewmodels to update
      updates_by_viewmodel_class.each do |viewmodel_class, updates|
        dependencies = updates.map { |_, upd| upd.preload_dependencies(referenced_updates) }
                       .inject { |acc, deps| acc.merge!(deps) }

        model_ids = updates.map { |_, update_data| update_data.id unless update_data.new? }.compact

        existing_models =
          if model_ids.present?
            model_class = viewmodel_class.model_class
            models = model_class.where(model_class.primary_key => model_ids).to_a

            if models.size < model_ids.size
              missing_model_ids = model_ids - models.map(&:id)
              missing_viewmodel_refs = missing_model_ids.map  { |id| ViewModel::Reference.new(viewmodel_class, id) }
              raise ViewModel::DeserializationError::NotFound.new(
                      "Couldn't find #{model_class.name}(s) with id(s)=#{missing_model_ids.inspect}",
                      missing_viewmodel_refs)
            end

            DeepPreloader.preload(models, dependencies)
            models.index_by(&:id)
          else
            {}
          end

        updates.each do |ref, update_data|
          viewmodel =
            if update_data.new?
              viewmodel_class.for_new_model(id: update_data.id)
            else
              viewmodel_class.new(existing_models[update_data.id])
            end

          update_op = new_update(viewmodel, update_data)

          if ref.nil?
            @root_update_operations << update_op
          else
            # TODO make sure that referenced subtree hashes are unique and provide a decent error message
            # not strictly necessary, but will save confusion
            @referenced_update_operations[ref] = update_op
          end
        end
      end

      self
    end

    # Applies updates and subsequently releases. Returns the updated viewmodels.
    def run!(deserialize_context:)
      updated_viewmodels = @root_update_operations.map do |root_update|
        root_update.run!(deserialize_context: deserialize_context)
      end

      @release_pool.release_all!(deserialize_context)

      updated_viewmodels
    end

    def assemble_update_tree
      @root_update_operations.each do |root_update|
        root_update.build!(self)
      end

      while @worklist.present?
        key = @worklist.keys.detect { |k| @release_pool.include?(k) }
        if key.nil?
          # All worklist viewmodels are unresolvable from roots. We need to
          # manually load unresolvable VMs, and additionally add their previous
          # parents (if present) as otherwise-unmodified roots with
          # `association_changed!` set, in order that we can correctly
          # `editable?` check them.

          # If the foreign key is from child to parent, the child update has a
          # `parent_data` for the new parent set, which will include the
          # reflection inverse and viewmodel. We can use that information to load
          # the previous parent.

          # TODO: If the foreign key is from the parent to the child however, it's
          # a little bit less safe. Even if we have the inverse relationship
          # recorded, if multiple other viewmodels are allowed to point into the
          # child (but only one at a time!) there's no way to safely move in all
          # conditions. One option would be to _try_ the inverse relationship: if
          # the inverse relationship resolves into a parent (of the same type) to
          # move from, we know it's safe to move (assuming the single-pointer
          # invariant previously held). If it doesn't though, we have no way of
          # knowing if it's actually unparented or if it's merely referred to from
          # a different parent type, so we are required to forbid the update.

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
            raise ViewModel::DeserializationError::NotFound.new(
                    "Cannot resolve previous parents for the following referenced viewmodels: #{vms}",
                    @worklist.keys)
          end

          # We are guaranteed to make progress or fail entirely.

          @worklist.delete(key)

          child_dependencies = deferred_update.update_data.preload_dependencies(@referenced_update_data)

          child_model = ViewModel::DeserializationError::NotFound.wrap_lookup(key) do
            key.viewmodel_class.model_class.find(key.model_id)
          end

          child_viewmodel = key.viewmodel_class.new(child_model)
          DeepPreloader.preload(child_model, child_dependencies)

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
          deferred_update.viewmodel = @release_pool.claim_from_pool(key).viewmodel
        end

        deferred_update.build!(self)
      end

      dangling_references = @referenced_update_operations.reject { |ref, upd| upd.built? }.map { |ref, upd| upd.viewmodel.to_reference }
      if dangling_references.present?
        raise ViewModel::DeserializationError.new("References not referred to from roots", dangling_references)
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

      return if parent_model_id.nil?

      ref = ViewModel::Reference.new(
        parent_viewmodel_class, parent_model_id)

      return if @updates_by_viewmodel[ref] == :implicit

      old_parent_model     = assoc.klass.find(parent_model_id)
      old_parent_viewmodel = parent_viewmodel_class.new(old_parent_model)

      update = new_update(old_parent_viewmodel,
                          UpdateData.empty_update_for(old_parent_viewmodel),
                          update_type: :implicit)

      update.build!(self)
      update.association_changed!(parent_association_name)
      @root_update_operations << update
      update
    end

    ## Methods for objects being built in this context

    # We require the updates to be recorded in the context so we can enforce the
    # property that each viewmodel is in the tree at most once. To avoid mistakes,
    # we require construction to go via methods that do this tracking.

    def new_deferred_update(viewmodel_reference, update_data, reparent_to: nil, reposition_to: nil)
      update_operation = ViewModel::ActiveRecord::UpdateOperation.new(
        nil, update_data, reparent_to: reparent_to, reposition_to: reposition_to)
      set_update_type(viewmodel_reference, :explicit)
      @worklist[viewmodel_reference] = update_operation
    end

    def new_update(viewmodel, update_data, reparent_to: nil, reposition_to: nil, update_type: :explicit)
      update = ViewModel::ActiveRecord::UpdateOperation.new(
        viewmodel, update_data, reparent_to: reparent_to, reposition_to: reposition_to)

      if (vm_ref = update.viewmodel_reference).present?
        set_update_type(vm_ref, update_type)
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
        raise ViewModel::DeserializationError.new("Not a valid type transition: #{current_type} -> #{new_type}", vm_ref)
      end
    end

    def resolve_reference(ref)
      @referenced_update_operations.fetch(ref) do
        raise ViewModel::DeserializationError.new("Could not find referenced data with key '#{ref}'", ref)
      end
    end

    def try_take_released_viewmodel(vm_ref)
      @release_pool.claim_from_pool(vm_ref).try(&:viewmodel)
    end

    def release_viewmodel(viewmodel, association_data)
      @release_pool.release_to_pool(viewmodel, association_data)
    end
  end
end
