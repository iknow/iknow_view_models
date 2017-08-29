require "active_support"
require "active_record"

require "view_model"
require "view_model/record"

require "lazily"
require "concurrent"

class ViewModel::ActiveRecord < ViewModel::Record
  # Defined before requiring components so components can refer to them at parse time

  # for functional updates
  FUNCTIONAL_UPDATE_TYPE = "_update"
  ACTIONS_ATTRIBUTE      = "actions"
  VALUES_ATTRIBUTE       = "values"
  BEFORE_ATTRIBUTE       = "before"
  AFTER_ATTRIBUTE        = "after"

  require 'view_model/active_record/collections'
  require 'view_model/active_record/association_data'
  require 'view_model/active_record/update_data'
  require 'view_model/active_record/update_context'
  require 'view_model/active_record/update_operation'
  require 'view_model/active_record/visitor'
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
        define_method("_list_attribute") do
          model.public_send(attr)
        end

        define_method("_list_attribute=") do |x|
          model.public_send(:"#{attr}=", x)
        end
      end
    end

    def _list_member?
      _list_attribute_name.present?
    end

    # Specifies an association from the model to be recursively serialized using
    # another viewmodel. If the target viewmodel is not specified, attempt to
    # locate a default viewmodel based on the name of the associated model.
    # TODO document harder
    # - +through+ names an ActiveRecord association that will be used like an
    #   ActiveRecord +has_many:through:+.
    # - +through_order_attr+ the through model is ordered by the given attribute
    #   (only applies to when +through+ is set).
    def association(association_name,
                    viewmodel: nil,
                    viewmodels: nil,
                    shared: false,
                    optional: shared,
                    through: nil,
                    through_order_attr: nil,
                    as: nil)

      if through
        model_association_name = through
        through_to             = association_name
      else
        model_association_name = association_name
        through_to             = nil
      end

      vm_association_name    = (as || association_name).to_s

      reflection = model_class.reflect_on_association(model_association_name)

      if reflection.nil?
        raise ArgumentError.new("Association #{model_association_name} not found in #{model_class.name} model")
      end

      viewmodel_spec = viewmodel || viewmodels

      association_data = AssociationData.new(vm_association_name, reflection, viewmodel_spec, shared, optional, through_to, through_order_attr)

      _members[vm_association_name] = association_data

      @generated_accessor_module.module_eval do
        define_method vm_association_name do
          _read_association(vm_association_name)
        end

        define_method :"serialize_#{vm_association_name}" do |json, serialize_context: self.class.new_serialize_context|
          associated = self.public_send(vm_association_name)
          json.set! vm_association_name do
            case
            when associated.nil?
              json.null!
            when association_data.through?
              json.array!(associated) do |through_target|
                self.class.serialize_as_reference(through_target, json, serialize_context: serialize_context)
              end
            when shared
              self.class.serialize_as_reference(associated, json, serialize_context: serialize_context)
            else
              self.class.serialize(associated, json, serialize_context: serialize_context)
            end
          end
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
                    "Couldn't find #{self.model_class.name}(s) with id(s)=#{missing_ids.inspect}",
                    missing_ids.map { |id| ViewModel::Reference.new(self, id) } )
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

          # Provide information about what was updated
          deserialize_context.updated_associations = root_update_data
                                                       .map { |upd| upd.updated_associations }
                                                       .inject({}) { |acc, assocs| acc.deep_merge(assocs) }

          _updated_viewmodels =
            UpdateContext
              .build!(root_update_data, referenced_update_data, root_type: self)
              .run!(deserialize_context: deserialize_context)
        end
      end
    end

    def eager_includes(serialize_context: new_serialize_context, include_shared: true)
      # When serializing, we need to (recursively) include all intrinsic
      # associations and also those optional (incl. shared) associations
      # specified in the serialize_context.

      # when deserializing, we start with intrinsic non-shared associations. We
      # then traverse the structure of the tree to deserialize to map out which
      # optional or shared associations are used from each type. We then explore
      # from the root type to build an preload specification that will include
      # them all. (We can subsequently use this same structure to build a
      # serialization context featuring the same associations.)

      association_specs = {}
      _members.each do |assoc_name, association_data|
        next unless association_data.is_a?(AssociationData)
        next unless serialize_context.includes_member?(assoc_name, !association_data.optional?)

        child_context = serialize_context.for_child(nil, association_name: assoc_name)

        case
        when association_data.through?
          viewmodel = association_data.direct_viewmodel
          children = viewmodel.eager_includes(serialize_context: child_context, include_shared: include_shared)

        when !include_shared && association_data.shared?
          children = nil # Load up to the shared model, but no further

        when association_data.polymorphic?
          children_by_klass = {}
          association_data.viewmodel_classes.each do |vm_class|
            klass = vm_class.model_class.name
            children_by_klass[klass] = vm_class.eager_includes(serialize_context: child_context, include_shared: include_shared)
          end
          children = DeepPreloader::PolymorphicSpec.new(children_by_klass)

        else
          viewmodel = association_data.viewmodel_class
          children = viewmodel.eager_includes(serialize_context: child_context, include_shared: include_shared)
        end

        association_specs[association_data.direct_reflection.name.to_s] = children
      end
      DeepPreloader::Spec.new(association_specs)
    end

    def dependent_viewmodels(seen = Set.new, include_shared: true)
      return if seen.include?(self)

      seen << self

      _members.each do |name, data|
        next unless data.is_a?(AssociationData)
        next unless include_shared || !data.shared?
        data.viewmodel_classes.each do |vm|
          vm.dependent_viewmodels(seen, include_shared: include_shared)
        end
      end

      seen
    end

    def deep_schema_version(include_shared: true)
      (@deep_schema_version ||= {})[include_shared] ||=
        begin
          dependent_viewmodels(include_shared: include_shared).each_with_object({}) do |view, h|
            h[view.view_name] = view.schema_version
          end
        end
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
    @changed_associations = []
  end

  # Allows a viewmodel to set a hook when a record is visited during
  # deserialization, for example for conservative cache clearing.
  def before_deserialize(deserialize_context:)
    # hook method; no default behaviour
  end

  # Allows a viewmodel to set a hook before a record is saved when
  # changes have been made during deserialization, for example for
  # setting default values. Any changes introduced here are still
  # subject to access control. Note that due to limitations on
  # ActiveRecord, changes to associations here must be explicitly
  # marked by calling `association_changed!`.
  def before_save(changes, deserialize_context:)
    # hook method; no default behaviour
  end

  def serialize_members(json, serialize_context: self.class.new_serialize_context)
    self.class._members.each do |member_name, member_data|
      next unless serialize_context.includes_member?(member_name, !member_data.optional?)

      member_context =
        case member_data
        when AssociationData
          member_context = serialize_context.for_child(self, association_name: member_name)
        else
          serialize_context
        end

      self.public_send("serialize_#{member_name}", json, serialize_context: member_context)
    end
  end

  def destroy!(deserialize_context: self.class.new_deserialize_context)
    model_class.transaction do
      deserialize_context.visible!(self)
      initial_editability = deserialize_context.initial_editability(self)
      deserialize_context.editable!(self,
                                    initial_editability: initial_editability,
                                    changes: ViewModel::Changes.new(deleted: true))
      model.destroy!
    end
  end

  def association_changed!(association_name)
    @changed_associations << association_name.to_s
  end

  def associations_changed?
    @changed_associations.present?
  end

  def clear_changed_associations!
    @changed_associations = []
  end

  def changes
    # We are a descendent of ViewModel::Record, so we do have the
    # change tracking for `new_model?` and `changed_attributes` here.
    #
    #   - we use `model.new_record?` instead of `self.new_model?` so
    #     that implementors of custom resolve steps aren't required to
    #     call `model_is_new!`
    #
    #   - we use `model.changed_attributes` instead of
    #     `self.changed_attributes` for similar reasons, that
    #     implementors of custom `deserialize_#{foo}` methods aren't
    #     required to call `attribute_changed!`

    changed_attributes = model.changed

    if model.class.locking_enabled?
      changed_attributes.delete(model.class.locking_column)
    end

    ViewModel::Changes.new(
      new:                  model.new_record?,
      changed_attributes:   changed_attributes,
      changed_associations: changed_associations)
  end

  def clear_changes!
    super
    @changed_associations = []
  end

  def _read_association(association_name)
    association_data = self.class._association_data(association_name)

    associated = model.public_send(association_data.direct_reflection.name)
    return nil if associated.nil?

    case
    when association_data.through?
      # associated here are join_table models; we need to get the far side out
      if association_data.direct_viewmodel._list_member?
        associated.order(association_data.direct_viewmodel._list_attribute_name)
      end

      associated.map do |through_model|
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

  self.abstract_class = true
end
