# frozen_string_literal: true

# Abstract ViewModel type for serializing a subset of attributes from a record.
# A record viewmodel wraps a single underlying model, exposing a fixed set of
# real or calculated attributes.
class ViewModel::Record < ViewModel
  # All ViewModel::Records have the same underlying ViewModel attribute: the
  # record model they back on to. We want this to be inherited by subclasses, so
  # we override ViewModel's :_attributes to close over it.
  attr_accessor :model

  require 'view_model/record/attribute_data'
  require 'view_model/migratable_view'

  include ViewModel::MigratableView

  class << self
    attr_reader :_members
    attr_accessor :abstract_class, :unregistered

    def inherited(subclass)
      super
      subclass.initialize_as_viewmodel_record
      ViewModel::Registry.register(subclass)
    end

    def initialize_as_viewmodel_record
      @_members       = {}
      @abstract_class = false
      @unregistered   = false

      @generated_accessor_module = Module.new
      include @generated_accessor_module
    end

    # Should this class be registered in the viewmodel registry
    def should_register?
      !abstract_class && !unregistered && !synthetic
    end

    # Specifies an attribute from the model to be serialized in this view
    def attribute(attr, as: nil, read_only: false, write_once: false, using: nil, format: nil, array: false)
      model_attribute_name = attr.to_s
      vm_attribute_name    = (as || attr).to_s

      if using && format
        raise ArgumentError.new("Only one of ':using' and ':format' may be specified")
      end
      if using && !(using.is_a?(Class) && using < ViewModel)
        raise ArgumentError.new("Invalid 'using:' viewmodel: not a viewmodel class")
      end
      if using && using.root?
        raise ArgumentError.new("Invalid 'using:' viewmodel: is a root")
      end
      if format && !format.respond_to?(:dump) && !format.respond_to?(:load)
        raise ArgumentError.new("Invalid 'format:' serializer: must respond to :dump and :load")
      end

      attr_data = AttributeData.new(name: vm_attribute_name,
                                    model_attr_name: model_attribute_name,
                                    attribute_viewmodel: using,
                                    attribute_serializer: format,
                                    array: array,
                                    read_only: read_only,
                                    write_once: write_once)
      _members[vm_attribute_name] = attr_data

      @generated_accessor_module.module_eval do
        define_method vm_attribute_name do
          _get_attribute(attr_data)
        end

        define_method "serialize_#{vm_attribute_name}" do |json, serialize_context: self.class.new_serialize_context|
          _serialize_attribute(attr_data, json, serialize_context: serialize_context)
        end

        define_method "deserialize_#{vm_attribute_name}" do |value, references: {}, deserialize_context: self.class.new_deserialize_context|
          _deserialize_attribute(attr_data, value, references: references, deserialize_context: deserialize_context)
        end
      end
    end

    def deserialize_from_view(view_hashes, references: {}, deserialize_context: new_deserialize_context)
      ViewModel::Utils.map_one_or_many(view_hashes) do |view_hash|
        view_hash = view_hash.dup
        metadata = ViewModel.extract_viewmodel_metadata(view_hash)

        unless self.view_name == metadata.view_name || self.view_aliases.include?(metadata.view_name)
          raise ViewModel::DeserializationError::InvalidViewType.new(
                  self.view_name,
                  ViewModel::Reference.new(self, metadata.id))
        end

        if metadata.schema_version && !self.accepts_schema_version?(metadata.schema_version)
          raise ViewModel::DeserializationError::SchemaVersionMismatch.new(
                  self, version, ViewModel::Reference.new(self, metadata.id))
        end

        viewmodel = resolve_viewmodel(metadata, view_hash, deserialize_context: deserialize_context)

        deserialize_members_from_view(viewmodel, view_hash, references: references, deserialize_context: deserialize_context)

        viewmodel
      end
    end

    def deserialize_members_from_view(viewmodel, view_hash, references:, deserialize_context:)
      super do |hook_control|
        final_changes = viewmodel.clear_changes!

        if final_changes.changed?
          deserialize_context.run_callback(ViewModel::Callbacks::Hook::OnChange, viewmodel, changes: final_changes)
        end

        hook_control.record_changes(final_changes)
      end
    end

    def resolve_viewmodel(_metadata, _view_hash, deserialize_context:)
      self.for_new_model
    end

    def for_new_model(*model_args)
      self.new(model_class.new(*model_args)).tap { |v| v.model_is_new! }
    end

    # Returns the AR model class wrapped by this viewmodel. If this has not been
    # set via `model_class_name=`, attempt to automatically resolve based on the
    # name of this viewmodel.
    def model_class
      unless instance_variable_defined?(:@model_class)
        # try to auto-detect the model class based on our name
        self.model_class_name =
          ViewModel::Registry.infer_model_class_name(self.view_name)
      end

      @model_class
    end

    def member_names
      self._members.keys
    end

    private

    # Set the record type to be wrapped by this viewmodel
    def model_class_name=(name)
      name = name.to_s

      type = name.safe_constantize

      if type.nil?
        raise ArgumentError.new("Could not find model class with name '#{name}'")
      end

      self.model_class = type
    end

    # Set the record type to be wrapped by this viewmodel
    def model_class=(type)
      if instance_variable_defined?(:@model_class)
        raise ArgumentError.new("Model class for ViewModel '#{self.name}' already set")
      end

      @model_class = type
    end
  end

  delegate :model_class, to: 'self.class'

  attr_reader :changed_attributes, :previous_changes

  def initialize(model)
    unless model.is_a?(model_class)
      raise ArgumentError.new("'#{model.inspect}' is not an instance of #{model_class.name}")
    end

    self.model = model

    @new_model                     = false
    @changed_attributes            = []
    @changed_nested_children       = false
    @changed_referenced_children   = false

    super()
  end

  # VM::Record identity matches the identity of its model. If the model has a
  # stable identity, use it, otherwise fall back to its object_id.
  def id
    if stable_id?
      model.id
    else
      model.object_id
    end
  end

  def stable_id?
    model.respond_to?(:id)
  end

  def new_model?
    @new_model
  end

  def changed_nested_children?
    @changed_nested_children
  end

  def changed_referenced_children?
    @changed_referenced_children
  end

  def serialize_view(json, serialize_context: self.class.new_serialize_context)
    json.set!(ViewModel::ID_ATTRIBUTE, self.id) if stable_id?
    json.set!(ViewModel::TYPE_ATTRIBUTE, self.view_name)
    json.set!(ViewModel::VERSION_ATTRIBUTE, self.class.schema_version)

    serialize_members(json, serialize_context: serialize_context)
  end

  def serialize_members(json, serialize_context:)
    self.class._members.each do |member_name, _member_data|
      self.public_send("serialize_#{member_name}", json, serialize_context: serialize_context)
    end
  end

  # Check that the model backing this view is consistent, for example by calling
  # AR validations. Default implementation handles ActiveModel::Validations, may
  # be overridden by subclasses for other types of validation. Must raise
  # DeserializationError::Validation if invalid.
  def validate!
    if model_class < ActiveModel::Validations && !model.valid?
      raise ViewModel::DeserializationError::Validation.from_active_model(model.errors, self.blame_reference)
    end
  end

  def model_is_new!
    @new_model = true
  end

  def attribute_changed!(attr_name)
    @changed_attributes << attr_name.to_s
  end

  def nested_children_changed!
    @changed_nested_children = true
  end

  def referenced_children_changed!
    @changed_referenced_children = true
  end

  def changes
    ViewModel::Changes.new(
      new:                         new_model?,
      changed_attributes:          changed_attributes,
      changed_nested_children:     changed_nested_children?,
      changed_referenced_children: changed_referenced_children?,
    )
  end

  def clear_changes!
    @previous_changes           = changes
    @new_model                  = false
    @changed_attributes         = []
    @changed_nested_children    = false
    @changed_referenced_children = false
    previous_changes
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

  self.abstract_class = true

  private

  def _get_attribute(attr_data)
    value = model.public_send(attr_data.model_attr_name)

    if attr_data.using_viewmodel? && !value.nil?
      # Where an attribute uses a viewmodel, the associated viewmodel type is
      # significant and may have behaviour: like with VM::ActiveRecord
      # associations it's useful to return the value wrapped in its viewmodel
      # type even when not serializing.
      value = attr_data.map_value(value) do |v|
        attr_data.attribute_viewmodel.new(v)
      end
    end

    value
  end

  def _serialize_attribute(attr_data, json, serialize_context:)
    vm_attr_name = attr_data.name

    value = self.public_send(vm_attr_name)

    if attr_data.using_serializer? && !value.nil?
      # Where an attribute uses a low level serializer (rather than another
      # viewmodel), it's only desired for converting the value to and from wire
      # format, so conversion is deferred to serialization time.
      value = attr_data.map_value(value) do |v|
        attr_data.attribute_serializer.dump(v, json: true)
      rescue IknowParams::Serializer::DumpError => ex
        raise ViewModel::SerializationError.new(
                "Could not serialize invalid value '#{vm_attr_name}': #{ex.message}")
      end
    end

    json.set! vm_attr_name do
      serialize_context = self.context_for_child(vm_attr_name, context: serialize_context) if attr_data.using_viewmodel?
      self.class.serialize(value, json, serialize_context: serialize_context)
    end
  end

  def _deserialize_attribute(attr_data, serialized_value, references:, deserialize_context:)
    vm_attr_name = attr_data.name

    if attr_data.array? && !serialized_value.nil?
      expect_type!(vm_attr_name, Array, serialized_value)
    end

    value =
      case
      when serialized_value.nil?
        serialized_value
      when attr_data.using_viewmodel?
        ctx = self.context_for_child(vm_attr_name, context: deserialize_context)
        attr_data.map_value(serialized_value) do |sv|
          attr_data.attribute_viewmodel.deserialize_from_view(sv, references: references, deserialize_context: ctx)
        end
      when attr_data.using_serializer?
        attr_data.map_value(serialized_value) do |sv|
          attr_data.attribute_serializer.load(sv)
        rescue IknowParams::Serializer::LoadError => ex
          reason = "could not be deserialized because #{ex.message}"
          raise ViewModel::DeserializationError::Validation.new(vm_attr_name, reason, {}, blame_reference)
        end
      else
        serialized_value
      end

    # Detect changes with ==. In the case of `using_viewmodel?`, this compares viewmodels or arrays of viewmodels.
    if value != self.public_send(vm_attr_name)
      if attr_data.read_only? && !(attr_data.write_once? && new_model?)
        raise ViewModel::DeserializationError::ReadOnlyAttribute.new(vm_attr_name, blame_reference)
      end

      attribute_changed!(vm_attr_name)

      if attr_data.using_viewmodel? && !value.nil?
        # Extract model from target viewmodel(s) to attach to our model
        value = attr_data.map_value(value) { |vm| vm.model }
      end

      model.public_send("#{attr_data.model_attr_name}=", value)
    end

    if attr_data.using_viewmodel?
      previous_changes = Array.wrap(value).select { |v| v.respond_to?(:previous_changes) }.map!(&:previous_changes)

      self.nested_children_changed!     if previous_changes.any? { |pc| pc.changed_nested_tree? }
      self.referenced_children_changed! if previous_changes.any? { |pc| pc.changed_referenced_children? }
    end
  end

  # Helper for type-checking input in hand-rolled deserialization: raises
  # DeserializationError unless the serialized value is of the provided type.
  def expect_type!(attribute, type, serialized_value)
    unless serialized_value.is_a?(type)
      raise ViewModel::DeserializationError::InvalidAttributeType.new(attribute.to_s,
                                                                      type.name,
                                                                      serialized_value.class.name,
                                                                      blame_reference)
    end
  end
end
