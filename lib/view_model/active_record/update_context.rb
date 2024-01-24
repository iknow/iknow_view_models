# frozen_string_literal: true

# Assembles an update operation tree from user input. Handles the interlinking
# and model of update operations, but does not handle the actual user data nor
# the mechanism by which it is applied to models.
class ViewModel::ActiveRecord
  class UpdateContext
    ReleaseEntry = Struct.new(:viewmodel, :association_data) do
      def initialize(*)
        super
        @claimed = false
      end

      def release!
        model = viewmodel.model
        case association_data.direct_reflection.options[:dependent]
        when :delete, :delete_all
          model.delete
        when :destroy, :destroy_async
          model.destroy
        end
      end

      def claimed!
        @claimed = true
      end

      def claimed?
        @claimed
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
        if (entry = @released_viewmodels.delete(key))
          entry.claimed!
          entry.viewmodel
        end
      end

      def release_all!
        @released_viewmodels.each_value(&:release!)
      end
    end

    def self.build!(root_update_data, referenced_update_data, root_type: nil)
      if root_type.present? && (bad_types = root_update_data.map(&:viewmodel_class).to_set.delete(root_type)).present?
        raise ViewModel::DeserializationError::InvalidViewType.new(root_type.view_name, bad_types.map { |t| ViewModel::Reference.new(t, nil) })
      end

      self.new
        .build_root_update_operations(root_update_data, referenced_update_data)
        .assemble_update_tree
    end

    # TODO: an unfortunate abstraction violation. The `append` case constructs an
    # update tree and later injects the context of parent and position.
    def root_updates
      @root_update_operations
    end

    def initialize
      @root_update_operations       = [] # The subject(s) of this update
      @referenced_update_operations = {} # data updates to other root models, referred to by a ref hash

      # Set of ViewModel::Reference used to assert only a single update is
      # present for each viewmodel
      @updated_viewmodel_references = Set.new

      # hash of { ViewModel::Reference => deferred UpdateOperation }
      # for linked partially-constructed node updates
      @worklist = {}

      @release_pool = ReleasePool.new
    end

    # Processes parsed (UpdateData) root updates and referenced updates into
    # @root_update_operations and @referenced_update_operations.
    def build_root_update_operations(root_updates, referenced_updates)
      # Look up viewmodel classes for each tree with eager_includes. Note this
      # won't yet include through a polymorphic boundary: for now we become
      # lazy-loading and slow every time that happens.

      # Combine our root and referenced updates, and separate by viewmodel type.
      # Sort by id where possible to obtain as close to possible a deterministic
      # update order to avoid database write deadlocks. This can't be entirely
      # comprehensive, since we can't control the order that shared references
      # are referred to from roots (and therefore visited).
      updates_by_viewmodel_class =
        root_updates.lazily
          .map { |root_update| [nil, root_update] }
          .concat(referenced_updates)
          .sort_by { |_, update_data| update_data.metadata.id.to_s }
          .group_by { |_, update_data| update_data.viewmodel_class }

      # For each viewmodel type, look up referenced models and construct viewmodels to update
      updates_by_viewmodel_class.each do |viewmodel_class, updates|
        dependencies = updates.map { |_, upd| upd.preload_dependencies }
                       .inject { |acc, deps| acc.merge!(deps) }

        model_ids = updates.map { |_, update_data| update_data.id unless update_data.new? }.compact

        existing_models =
          if model_ids.present?
            model_class = viewmodel_class.model_class
            models = model_class.where(model_class.primary_key => model_ids).to_a

            if models.size < model_ids.size
              missing_model_ids = model_ids - models.map(&:id)
              missing_viewmodel_refs = missing_model_ids.map { |id| ViewModel::Reference.new(viewmodel_class, id) }
              raise ViewModel::DeserializationError::NotFound.new(missing_viewmodel_refs)
            end

            DeepPreloader.preload(models, dependencies)
            models.index_by(&:id)
          else
            {}
          end

        updates.each do |ref, update_data|
          viewmodel =
            if update_data.auto_child_update?
              raise ViewModel::DeserializationError::InvalidStructure.new(
                      'Cannot make an automatic child update to a root node',
                      ViewModel::Reference.new(update_data.viewmodel_class, nil))
            elsif update_data.child_update?
              raise ViewModel::DeserializationError::InvalidStructure.new(
                      'Cannot update an existing root node without a specified id',
                      ViewModel::Reference.new(update_data.viewmodel_class, nil))
            elsif update_data.new?
              viewmodel_class.for_new_model(id: update_data.id)
            else
              viewmodel_class.new(existing_models[update_data.id])
            end

          update_op = new_update(viewmodel, update_data)

          if ref.nil?
            @root_update_operations << update_op
          else
            # TODO: make sure that referenced subtree hashes are unique and provide a decent error message
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

      @release_pool.release_all!

      if updated_viewmodels.present? && deserialize_context.validate_deferred_constraints?
        # Deferred database constraints may have been violated by changes during
        # deserialization. VM::AR promises that any errors during deserialization
        # will be raised as a ViewModel::DeserializationError, so check constraints
        # and raise before exit.
        check_deferred_constraints!(updated_viewmodels.first.model.class)
      end

      updated_viewmodels
    end

    def assemble_update_tree
      @root_update_operations.each do |root_update|
        root_update.build!(self)
      end

      while @worklist.present?
        key = @worklist.keys.detect { |k| @release_pool.include?(k) }
        if key.nil?
          raise ViewModel::DeserializationError::ParentNotFound.new(@worklist.keys)
        end

        deferred_update    = @worklist.delete(key)
        released_viewmodel = @release_pool.claim_from_pool(key)

        if deferred_update.viewmodel
          # Deferred reference updates already have a viewmodel: ensure it
          # matches the tree
          unless deferred_update.viewmodel == released_viewmodel
            raise ViewModel::DeserializationError::Internal.new(
                    "Released viewmodel doesn't match reference update", blame_reference)
          end
        else
          deferred_update.viewmodel = released_viewmodel
        end

        deferred_update.build!(self)
      end

      dangling_references = @referenced_update_operations.reject { |_ref, upd| upd.built? }.map { |_ref, upd| upd.viewmodel.to_reference }
      if dangling_references.present?
        raise ViewModel::DeserializationError::InvalidStructure.new('References not referred to from roots', dangling_references)
      end

      self
    end

    ## Methods for objects being built in this context

    # We require the updates to be recorded in the context so we can enforce the
    # property that each viewmodel is in the tree at most once. To avoid mistakes,
    # we require construction to go via methods that do this tracking.

    def new_deferred_update(viewmodel_reference, update_data, reparent_to: nil, reposition_to: nil)
      update_operation = ViewModel::ActiveRecord::UpdateOperation.new(
        nil, update_data, reparent_to: reparent_to, reposition_to: reposition_to)
      check_unique_update!(viewmodel_reference)
      defer_update(viewmodel_reference, update_operation)
    end

    # Defer an existing update: used if we need to ensure that an owned
    # reference has been freed before we use it.
    def defer_update(viewmodel_reference, update_operation)
      @worklist[viewmodel_reference] = update_operation
    end

    def new_update(viewmodel, update_data, reparent_to: nil, reposition_to: nil)
      update = ViewModel::ActiveRecord::UpdateOperation.new(
        viewmodel, update_data, reparent_to: reparent_to, reposition_to: reposition_to)

      if (vm_ref = update.viewmodel_reference).present?
        check_unique_update!(vm_ref)
      end

      update
    end

    def check_unique_update!(vm_ref)
      unless @updated_viewmodel_references.add?(vm_ref)
        raise ViewModel::DeserializationError::DuplicateNodes.new(vm_ref.viewmodel_class.view_name, vm_ref)
      end
    end

    def resolve_reference(ref, blame_reference)
      @referenced_update_operations.fetch(ref) do
        raise ViewModel::DeserializationError::InvalidSharedReference.new(ref, blame_reference)
      end
    end

    def try_take_released_viewmodel(vm_ref)
      @release_pool.claim_from_pool(vm_ref)
    end

    def release_viewmodel(viewmodel, association_data)
      @release_pool.release_to_pool(viewmodel, association_data)
    end

    # Immediately enforce any deferred database constraints (when using
    # Postgres) and convert them to DeserializationErrors.
    #
    # Note that there's no effective way to tie such a failure back to the
    # individual node that caused it, without attempting to parse Postgres'
    # human-readable error details.
    def check_deferred_constraints!(model_class)
      if model_class.connection.adapter_name == 'PostgreSQL'
        model_class.connection.execute('SET CONSTRAINTS ALL IMMEDIATE')
      end
    rescue ::ActiveRecord::StatementInvalid => ex
      raise ViewModel::DeserializationError::DatabaseConstraint.from_exception(ex)
    end
  end
end
