require "active_support"
require "active_record"

require "view_model"

require "cerego_active_record_patches"
require "lazily"
require "concurrent"

class ViewModel::ActiveRecord < ViewModel
  # Defined before requiring components so components can refer to them at parse time
  NEW_ATTRIBUTE       = "_new"

  # for functional updates
  FUNCTIONAL_UPDATE_TYPE = "_update"
  ACTIONS_ATTRIBUTE      = "actions"
  VALUES_ATTRIBUTE       = "values"
  BEFORE_ATTRIBUTE       = "before"
  AFTER_ATTRIBUTE        = "after"

  require 'view_model/active_record/collections'
  require 'view_model/active_record/attribute_data'
  require 'view_model/active_record/association_data'
  require 'view_model/active_record/update_data'
  require 'view_model/active_record/update_context'
  require 'view_model/active_record/update_operation'
  require 'view_model/active_record/visitor'

  # An AR ViewModel wraps a single AR model
  attribute :model

  @@viewmodel_classes_by_name  = Concurrent::Map.new
  @@deferred_viewmodel_classes = Concurrent::Array.new

  class << self
    attr_reader :_members, :_list_attribute_name
    attr_accessor :abstract_class, :synthetic, :unregistered

    delegate :transaction, to: :model_class

    def for_view_name(name)
      raise ViewModel::DeserializationError.new("ViewModel name cannot be nil") if name.nil?

      # Resolve names for any deferred viewmodel classes
      until @@deferred_viewmodel_classes.empty? do
        vm = @@deferred_viewmodel_classes.pop
        @@viewmodel_classes_by_name[vm.view_name] = vm unless vm.abstract_class || vm.synthetic || vm.unregistered
      end

      viewmodel_class = @@viewmodel_classes_by_name[name]

      if viewmodel_class.nil? || !(viewmodel_class < ViewModel::ActiveRecord)
        raise ViewModel::DeserializationError.new("ViewModel class for view name '#{name}' not found")
      end

      viewmodel_class
    end

    def inherited(subclass)
      # copy ViewModel setup
      subclass._attributes = self._attributes

      subclass.initialize_members

      # Store the subclass for later view name resolution
      @@deferred_viewmodel_classes << subclass
    end

    def initialize_members
      @_members = {}
      @abstract_class = false
      @unregistered = false

      @generated_accessor_module = Module.new
      include @generated_accessor_module
    end

    # Specifies an attribute from the model to be serialized in this view
    def attribute(attr, read_only: false, using: nil, optional: false)
      _members[attr.to_s] = AttributeData.new(using, optional)

      @generated_accessor_module.module_eval do
        define_method attr do
          val = model.public_send(attr)
          val = using.new(val) if using.present?
          val
        end

        define_method "serialize_#{attr}" do |json, serialize_context: self.class.new_serialize_context|
          value = self.public_send(attr)
          json.set! attr do
            self.class.serialize(value, json, serialize_context: serialize_context)
          end
        end

        if read_only
          define_method "deserialize_#{attr}" do |value, deserialize_context: self.class.new_deserialize_context|
            value = using.deserialize_from_view(value, deserialize_context: deserialize_context.for_child(self)) if using.present?
            if value != self.public_send(attr)
              raise ViewModel::DeserializationError.new("Cannot edit read only attribute: #{attr}", self.blame_reference)
            end
          end
        else
          define_method "deserialize_#{attr}" do |value, deserialize_context: self.class.new_deserialize_context|
            value = using.deserialize_from_view(value, deserialize_context: deserialize_context.for_child(self)).model if using.present?
            model.public_send("#{attr}=", value)
          end
        end
      end
    end

    # Specifies that an attribute refers to an `acts_as_enum` constant.  This
    # provides special serialization behaviour to ensure that the constant's
    # string value is serialized rather than the model object.
    def acts_as_enum(*attrs)
      attrs.each do |attr|
        @generated_accessor_module.module_eval do
          redefine_method("serialize_#{attr}") do |json, serialize_context: self.class.new_serialize_context|
            value = self.public_send(attr)
            json.set! attr do
              self.class.serialize(value.try(:enum_constant), json, serialize_context: serialize_context)
            end
          end
          redefine_method("deserialize_#{attr}") do |value, deserialize_context: self.class.deserialize_context|
            begin
              model.public_send("#{attr}=", value)
            rescue NameError
              raise ViewModel::DeserializationError.new("Invalid enumeration constant '#{value}'", self.blame_reference)
            end
          end
        end
      end
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
          read_association(vm_association_name)
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

    ## Load an instance of the viewmodel by id
    def find(id, scope: nil, eager_include: true, serialize_context: new_serialize_context)
      find_scope = self.model_class.all
      find_scope = find_scope.merge(scope) if scope

      ref = ViewModel::Reference.new(self, id)
      model = ViewModel::DeserializationError::NotFound.wrap_lookup(ref) do
        find_scope.find(id)
      end

      vm = self.new(model)
      ViewModel.preload_for_serialization(vm, serialize_context: serialize_context) if eager_include
      vm
    end

    ## Load instances of the viewmodel by scope
    ## TODO: is this too much of a encapsulation violation?
    def load(scope: nil, eager_include: true, serialize_context: new_serialize_context)
      load_scope = self.model_class.all
      load_scope = load_scope.merge(scope) if scope
      vms = load_scope.map { |model| self.new(model) }
      ViewModel.preload_for_serialization(vms, serialize_context: serialize_context) if eager_include
      vms
    end

    def deserialize_from_view(subtree_hashes, references: {}, deserialize_context: new_deserialize_context)
      model_class.transaction do
        return_array = subtree_hashes.is_a?(Array)
        subtree_hashes = Array.wrap(subtree_hashes)

        root_update_data, referenced_update_data = UpdateData.parse_hashes(subtree_hashes, references)

        # Provide information about will was updated
        deserialize_context.updated_associations = root_update_data
                                                     .map { |upd| upd.updated_associations(referenced_update_data) }
                                                     .inject({}) { |acc, assocs| acc.deep_merge(assocs) }

        updated_viewmodels =
          UpdateContext
            .build!(root_update_data, referenced_update_data, root_type: self)
            .run!(deserialize_context: deserialize_context)

        if return_array
          updated_viewmodels
        else
          updated_viewmodels.first
        end
      end
    end

    def eager_includes(serialize_context: new_serialize_context)
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
        child_context = serialize_context.for_association(assoc_name)

        case
        when association_data.through?
          viewmodel = association_data.through_viewmodel
          children = viewmodel.eager_includes(serialize_context: child_context)

        when association_data.polymorphic?
          children_by_klass = {}
          association_data.viewmodel_classes.each do |vm_class|
            klass = vm_class.model_class.name
            children_by_klass[klass] = vm_class.eager_includes(serialize_context: child_context)
          end
          children = DeepPreloader::PolymorphicSpec.new(children_by_klass)

        else
          viewmodel = association_data.viewmodel_class
          children = viewmodel.eager_includes(serialize_context: child_context)
        end

        association_specs[association_data.direct_reflection.name.to_s] = children
      end
      DeepPreloader::Spec.new(association_specs)
    end

    # Returns the AR model class wrapped by this viewmodel. If this has not been
    # set via `model_class_name=`, attempt to automatically resolve based on the
    # name of this viewmodel.
    def model_class
      unless instance_variable_defined?(:@model_class)
        # try to auto-detect the model class based on our name
        self.model_class_name = self.view_name
      end

      @model_class
    end

    def member_names
      self._members.keys
    end

    # internal
    def _association_data(association_name)
      association_data = self._members[association_name.to_s]
      raise ArgumentError.new("Invalid association") unless association_data.is_a?(AssociationData)
      association_data
    end

    private

    # Set the AR model to be wrapped by this viewmodel
    def model_class_name=(name)
      type = name.to_s.camelize.safe_constantize
      raise ArgumentError.new("Could not find model class '#{name}'") if type.nil?
      self.model_class = type
    end

    # Set the AR model to be wrapped by this viewmodel
    def model_class=(type)
      if instance_variable_defined?(:@model_class)
        raise ArgumentError.new("Model class for ViewModel '#{self.name}' already set")
      end

      unless type < ::ActiveRecord::Base
        raise ArgumentError.new("'#{type.inspect}' is not a valid ActiveRecord model class")
      end
      @model_class = type
    end
  end

  delegate :model_class, to: 'self.class'
  delegate :id, to: :model

  def initialize(model)
    unless model.is_a?(model_class)
      raise ArgumentError.new("'#{model.inspect}' is not an instance of #{model_class.name}")
    end

    super(model)
  end

  def self.for_new_model(id: nil)
    self.new(model_class.new(id: id))
  end

  # Use ActiveRecord style identity for viewmodels. This allows serialization to
  # generate a references section by keying on the viewmodel itself.
  def hash
    [self.class, self.model].hash
  end

  def ==(other)
    self.class == other.class && self.model == other.model
  end

  alias eql? ==

  def serialize_view(json, serialize_context: self.class.new_serialize_context)
    json.set!(ViewModel::ID_ATTRIBUTE, model.id)
    json.set!(ViewModel::TYPE_ATTRIBUTE, self.class.view_name)

    serialize_members(json, serialize_context: serialize_context)
  end

  def serialize_members(json, serialize_context: self.class.new_serialize_context)
    self.class._members.each do |member_name, member_data|
      next unless serialize_context.includes_member?(member_name, !member_data.optional?)

      member_context =
        case member_data
        when AssociationData
          member_context = serialize_context.for_association(member_name)
        else
          serialize_context
        end

      self.public_send("serialize_#{member_name}", json, serialize_context: member_context)
    end
  end

  def destroy!(deserialize_context: self.class.new_deserialize_context)
    model_class.transaction do
      editable!(deserialize_context: deserialize_context, deleted: true)
      model.destroy!
    end
  end

  def load_associated(association_name)
    self.public_send(association_name)
  end

  def find_associated(association_name, id, eager_include: true, serialize_context: self.class.new_serialize_context)
    association_data = self.class._association_data(association_name)
    associated_viewmodel = association_data.viewmodel_class
    association_scope = self.model.association(association_name).association_scope
    associated_viewmodel.find(id, scope: association_scope, eager_include: eager_include, serialize_context: serialize_context)
  end

  # Create or update a single member of an associated collection. For an ordered
  # collection, the new item is added at the end appended.
  def append_associated(association_name, subtree_hashes, references: {}, deserialize_context: self.class.new_deserialize_context)
    return_array = subtree_hashes.is_a?(Array)
    subtree_hashes = Array.wrap(subtree_hashes)

    model_class.transaction do
      editable!(deserialize_context: deserialize_context, changed_associations: [association_name])

      association_data = self.class._association_data(association_name)

      raise ArgumentError.new("Cannot append to single association '#{association_name}'") unless association_data.collection?

      associated_viewmodel_class = association_data.viewmodel_class

      # Construct an update operation tree for the provided child hashes
      viewmodel_class = association_data.viewmodel_class

      root_update_data, referenced_update_data = UpdateData.parse_hashes(subtree_hashes, references)
      update_context = UpdateContext.build!(root_update_data, referenced_update_data, root_type: viewmodel_class)

      # Provide information about what was updated
      deserialize_context.updated_associations = root_update_data
                                                   .map { |upd| upd.updated_associations(referenced_update_data) }
                                                   .inject({}) { |acc, assocs| acc.deep_merge(assocs) }

      # Set new parent
      new_parent = ViewModel::ActiveRecord::UpdateOperation::ParentData.new(association_data.direct_reflection.inverse_of, self)
      update_context.root_updates.each { |update| update.reparent_to = new_parent }

      # Set place in list
      if associated_viewmodel_class._list_member?
        last_position = model.association(association_name).scope.maximum(associated_viewmodel_class._list_attribute_name) || 0
        base_position = last_position + 1.0
        update_context.root_updates.each_with_index { |update, index| update.reposition_to = base_position + index }
      end

      updated_viewmodels = update_context.run!(deserialize_context: deserialize_context)

      if return_array
        updated_viewmodels
      else
        updated_viewmodels.first
      end
    end
  end

  # Removes the association between the models represented by this viewmodel and
  # the provided associated viewmodel. The associated model will be
  # garbage-collected if the assocation is specified with `dependent: :destroy`
  # or `:delete_all`
  def delete_associated(association_name, associated, deserialize_context: self.class.new_deserialize_context)
    model_class.transaction do
      editable!(deserialize_context: deserialize_context, changed_associations: [association_name])

      association_data = self.class._association_data(association_name)

      unless association_data.collection?
        raise ArgumentError.new("Cannot remove element from single association '#{association_name}'")
      end

      association = model.association(association_name)
      association.delete(associated.model)
    end
  end

  def read_association(association_name)
    association_data = self.class._association_data(association_name)

    associated = model.public_send(association_data.direct_reflection.name)
    return nil if associated.nil?

    case
    when association_data.through?
      # associated here are join_table models; we need to get the far side out
      if association_data.through_viewmodel._list_member?
        associated.order(association_data.through_viewmodel._list_attribute_name)
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
end
