# frozen_string_literal: true

require 'active_support'
require 'active_record'

require 'view_model'
require 'view_model/record'

require 'lazily'
require 'concurrent'

class ViewModel::ActiveRecord < ViewModel::Record
  # Defined before requiring components so components can refer to them at parse time

  # for functional updates
  FUNCTIONAL_UPDATE_TYPE = '_update'
  ACTIONS_ATTRIBUTE      = 'actions'
  VALUES_ATTRIBUTE       = 'values'
  BEFORE_ATTRIBUTE       = 'before'
  AFTER_ATTRIBUTE        = 'after'

  require 'view_model/utils/collections'
  require 'view_model/active_record/association_data'
  require 'view_model/active_record/update_data'
  require 'view_model/active_record/update_context'
  require 'view_model/active_record/update_operation'
  require 'view_model/active_record/visitor'
  require 'view_model/active_record/cloner'
  require 'view_model/active_record/cache'
  require 'view_model/active_record/association_manipulation'

  include AssociationManipulation

  attr_reader :changed_associations

  class << self
    attr_reader   :_list_attribute_name
    attr_accessor :synthetic

    delegate :transaction, to: :model_class

    def should_register?
      super && !synthetic
    end

    # Specifies that the model backing this viewmodel is a member of an
    # `acts_as_manual_list` collection.
    def acts_as_list(attr = :position)
      @_list_attribute_name = attr

      @generated_accessor_module.module_eval do
        define_method('_list_attribute') do
          model.public_send(attr)
        end

        define_method('_list_attribute=') do |x|
          model.public_send(:"#{attr}=", x)
        end
      end
    end

    def _list_member?
      _list_attribute_name.present?
    end

    # Adds an association from the model to this viewmodel. The associated model
    # will be recursively (de)serialized by its own viewmodel type, which will
    # be inferred from the model name, or may be explicitly specified.
    #
    # An association to a root viewmodel type will be serialized with an
    # indirect reference, while a child viewmodel type will be directly nested.
    #
    # - +as+ sets the name of the association in the viewmodel
    #
    # - +viewmodel+, +viewmodels+ specifies the viewmodel(s) to use for the
    #   association
    #
    # - +external+ indicates an association external to the view. Externalized
    #   associations are not included in (de)serializations of the parent, and
    #   must be independently manipulated using `AssociationManipulation`.
    #   External associations may only be made to root viewmodels.
    #
    # - +through+ names an ActiveRecord association that will be used like an
    #   ActiveRecord +has_many:through:+.
    #
    # - +through_order_attr+ the through model is ordered by the given attribute
    #   (only applies to when +through+ is set).
    def association(association_name,
                    as: nil,
                    viewmodel: nil,
                    viewmodels: nil,
                    external: false,
                    read_only: false,
                    through: nil,
                    through_order_attr: nil)

      vm_association_name = (as || association_name).to_s

      if through
        direct_association_name   = through
        indirect_association_name = association_name
      else
        direct_association_name   = association_name
        indirect_association_name = nil
      end

      target_viewmodels = Array.wrap(viewmodel || viewmodels)

      association_data = AssociationData.new(
        owner:                     self,
        association_name:          vm_association_name,
        direct_association_name:   direct_association_name,
        indirect_association_name: indirect_association_name,
        target_viewmodels:         target_viewmodels,
        external:                  external,
        read_only:                 read_only,
        through_order_attr:        through_order_attr)

      _members[vm_association_name] = association_data

      @generated_accessor_module.module_eval do
        define_method vm_association_name do
          _read_association(vm_association_name)
        end

        define_method :"serialize_#{vm_association_name}" do |json, serialize_context: self.class.new_serialize_context|
          _serialize_association(vm_association_name, json, serialize_context: serialize_context)
        end
      end
    end

    # Specify multiple associations at once
    def associations(*assocs, **args)
      assocs.each { |assoc| association(assoc, **args) }
    end

    ## Load instances of the viewmodel by id(s)
    def find(id_or_ids, scope: nil, lock: nil, eager_include: true, serialize_context: new_serialize_context)
      find_scope = self.model_class.all
      find_scope = find_scope.order(:id).lock(lock) if lock
      find_scope = find_scope.merge(scope) if scope

      ViewModel::Utils.wrap_one_or_many(id_or_ids) do |ids|
        models = find_scope.where(id: ids).to_a

        if models.size < ids.size
          missing_ids = ids - models.map(&:id)
          if missing_ids.present?
            raise ViewModel::DeserializationError::NotFound.new(
                    missing_ids.map { |id| ViewModel::Reference.new(self, id) })
          end
        end

        vms = models.map { |m| self.new(m) }
        ViewModel.preload_for_serialization(vms, lock: lock, serialize_context: serialize_context) if eager_include
        vms
      end
    end

    ## Load instances of the viewmodel by scope
    ## TODO: is this too much of a encapsulation violation?
    def load(scope: nil, eager_include: true, lock: nil, serialize_context: new_serialize_context)
      load_scope = self.model_class.all
      load_scope = load_scope.lock(lock) if lock
      load_scope = load_scope.merge(scope) if scope
      vms = load_scope.map { |model| self.new(model) }
      ViewModel.preload_for_serialization(vms, lock: lock, serialize_context: serialize_context) if eager_include
      vms
    end

    def deserialize_from_view(subtree_hash_or_hashes, references: {}, deserialize_context: new_deserialize_context)
      model_class.transaction do
        ViewModel::Utils.wrap_one_or_many(subtree_hash_or_hashes) do |subtree_hashes|
          root_update_data, referenced_update_data = UpdateData.parse_hashes(subtree_hashes, references)

          _updated_viewmodels =
            UpdateContext
              .build!(root_update_data, referenced_update_data, root_type: self)
              .run!(deserialize_context: deserialize_context)
        end
      end
    end

    # Constructs a preload specification of the required models for
    # serializing/deserializing this view. Cycles in the schema will be broken
    # after two layers of eager loading.
    def eager_includes(serialize_context: new_serialize_context, include_referenced: true, vm_path: [])
      association_specs = {}

      return nil if vm_path.count(self) > 2

      child_path = vm_path + [self]
      _members.each do |assoc_name, association_data|
        next unless association_data.is_a?(AssociationData)
        next if association_data.external?

        child_context =
          if self.synthetic
            serialize_context
          elsif association_data.referenced?
            serialize_context.for_references
          else
            serialize_context.for_child(nil, association_name: assoc_name)
          end

        case
        when association_data.through?
          viewmodel = association_data.direct_viewmodel
          children = viewmodel.eager_includes(serialize_context: child_context, include_referenced: include_referenced, vm_path: child_path)

        when !include_referenced && association_data.referenced?
          children = nil # Load up to the root viewmodel, but no further

        when association_data.polymorphic?
          children_by_klass = {}
          association_data.viewmodel_classes.each do |vm_class|
            klass = vm_class.model_class.name
            children_by_klass[klass] = vm_class.eager_includes(serialize_context: child_context, include_referenced: include_referenced, vm_path: child_path)
          end
          children = DeepPreloader::PolymorphicSpec.new(children_by_klass)

        else
          viewmodel = association_data.viewmodel_class
          children = viewmodel.eager_includes(serialize_context: child_context, include_referenced: include_referenced, vm_path: child_path)
        end

        association_specs[association_data.direct_reflection.name.to_s] = children
      end
      DeepPreloader::Spec.new(association_specs)
    end

    def dependent_viewmodels(seen = Set.new, include_referenced: true, include_external: true)
      return if seen.include?(self)

      seen << self

      _members.each_value do |data|
        next unless data.is_a?(AssociationData)
        next unless include_referenced || !data.referenced?
        next unless include_external   || !data.external?

        data.viewmodel_classes.each do |vm|
          vm.dependent_viewmodels(seen, include_referenced: include_referenced, include_external: include_external)
        end
      end

      seen
    end

    def deep_schema_version(include_referenced: true, include_external: true)
      (@deep_schema_version ||= {})[[include_referenced, include_external]] ||=
        begin
          vms = dependent_viewmodels(include_referenced: include_referenced, include_external: include_external)
          ViewModel.schema_versions(vms).freeze
        end
    end

    def cacheable!(**opts)
      include ViewModel::ActiveRecord::Cache::CacheableView
      create_viewmodel_cache!(**opts)
    end

    # internal
    def _association_data(association_name)
      association_data = self._members[association_name.to_s]
      raise ArgumentError.new("Invalid association '#{association_name}'") unless association_data.is_a?(AssociationData)

      association_data
    end
  end

  def initialize(*)
    super
    model_is_new! if model.new_record?
    @changed_associations = []
  end

  def serialize_members(json, serialize_context: self.class.new_serialize_context)
    self.class._members.each do |member_name, member_data|
      next if member_data.association? && member_data.external?

      member_context =
        case member_data
        when AssociationData
          self.context_for_child(member_name, context: serialize_context)
        else
          serialize_context
        end

      self.public_send("serialize_#{member_name}", json, serialize_context: member_context)
    end
  end

  def destroy!(deserialize_context: self.class.new_deserialize_context)
    model_class.transaction do
      ViewModel::Callbacks.wrap_deserialize(self, deserialize_context: deserialize_context) do |hook_control|
        changes = ViewModel::Changes.new(deleted: true)
        deserialize_context.run_callback(ViewModel::Callbacks::Hook::OnChange, self, changes: changes)
        hook_control.record_changes(changes)
        model.destroy!
      end
    end
  end

  def association_changed!(association_name)
    association_name = association_name.to_s

    association_data = self.class._association_data(association_name)

    if association_data.read_only?
      raise ViewModel::DeserializationError::ReadOnlyAssociation.new(association_name, blame_reference)
    end

    unless @changed_associations.include?(association_name)
      @changed_associations << association_name
    end
  end

  def associations_changed?
    @changed_associations.present?
  end

  # Additionally pass `changed_associations` while constructing changes.
  def changes
    ViewModel::Changes.new(
      new:                         new_model?,
      changed_attributes:          changed_attributes,
      changed_associations:        changed_associations,
      changed_nested_children:     changed_nested_children?,
      changed_referenced_children: changed_referenced_children?,
    )
  end

  def clear_changes!
    super.tap do
      @changed_associations = []
    end
  end

  def _read_association(association_name)
    association_data = self.class._association_data(association_name)

    associated = model.public_send(association_data.direct_reflection.name)
    return nil if associated.nil?

    case
    when association_data.through?
      # associated here are join-table models; we need to get the far side out
      join_models = associated

      if association_data.direct_viewmodel._list_member?
        attr = association_data.direct_viewmodel._list_attribute_name
        join_models = join_models.sort_by { |j| j[attr] }
      end

      join_models.map do |through_model|
        model = through_model.public_send(association_data.indirect_reflection.name)
        association_data.viewmodel_class_for_model!(model.class).new(model)
      end

    when association_data.collection?
      associated_viewmodel_class = association_data.viewmodel_class
      associated_viewmodels = associated.map { |x| associated_viewmodel_class.new(x) }
      if associated_viewmodel_class._list_member?
        associated_viewmodels.sort_by!(&:_list_attribute)
      end
      associated_viewmodels

    else
      associated_viewmodel_class = association_data.viewmodel_class_for_model!(associated.class)
      associated_viewmodel_class.new(associated)
    end
  end

  def _serialize_association(association_name, json, serialize_context:)
    associated = self.public_send(association_name)
    association_data = self.class._association_data(association_name)

    json.set! association_name do
      case
      when associated.nil?
        json.null!
      when association_data.referenced?
        if association_data.collection?
          json.array!(associated) do |target|
            self.class.serialize_as_reference(target, json, serialize_context: serialize_context)
          end
        else
          self.class.serialize_as_reference(associated, json, serialize_context: serialize_context)
        end
      else
        self.class.serialize(associated, json, serialize_context: serialize_context)
      end
    end
  end

  def context_for_child(member_name, context:)
    # Synthetic viewmodels don't exist as far as the traversal context is
    # concerned: pass through the child context received from the parent
    return context if self.class.synthetic

    # associations to roots start a new tree
    member_data = self.class._members[member_name.to_s]
    if member_data.association? && member_data.referenced?
      return context.for_references
    end

    super
  end

  self.abstract_class = true
end
