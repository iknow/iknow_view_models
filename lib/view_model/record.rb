require 'view_model/schemas'

# Abstract ViewModel type for serializing a subset of attributes from a record.
# A record viewmodel wraps a single underlying model, exposing a fixed set of
# real or calculated attributes.
class ViewModel::Record < ViewModel
  # All ViewModel::Records have the same underlying ViewModel attribute: the
  # record model they back on to. We want this to be inherited by subclasses, so
  # we override ViewModel's :_attributes to close over it.
  attribute :model
  self.lock_attribute_inheritance

  require 'view_model/record/attribute_data'

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
      !abstract_class && !unregistered
    end

    # Specifies an attribute from the model to be serialized in this view
    def attribute(attr, read_only: false, write_once: false, using: nil, array: false, optional: false)
      attr_data = AttributeData.new(attr, using, array, optional, read_only, write_once)
      _members[attr.to_s] = attr_data

      @generated_accessor_module.module_eval do
        define_method attr do
          _get_attribute(attr_data)
        end

        define_method "serialize_#{attr}" do |json, serialize_context: self.class.new_serialize_context|
          _serialize_attribute(attr_data, json, serialize_context: serialize_context)
        end

        define_method "deserialize_#{attr}" do |value, references: {}, deserialize_context: self.class.new_deserialize_context|
          _deserialize_attribute(attr_data, value, references: references, deserialize_context: deserialize_context)
        end
      end
    end

    def deserialize_from_view(view_hashes, references: {}, deserialize_context: new_deserialize_context)
      ViewModel::Utils.map_one_or_many(view_hashes) do |view_hash|
        view_hash = view_hash.dup
        type, version, id, new = ViewModel.extract_viewmodel_metadata(view_hash)

        if type != self.view_name
          raise ViewModel::DeserializationError.new(
                  "Cannot deserialize type #{type}, expected #{self.view_name}.",
                  ViewModel::Reference.new(self, id))
        end

        if version && !self.accepts_schema_version?(version)
          raise ViewModel::DeserializationError::SchemaMismatch.new(
                  "Mismatched schema version for type #{self.view_name}, "\
                  "expected #{self.schema_version}, received #{version}.",
                  ViewModel::Reference.new(self, id))
        end

        viewmodel = resolve_viewmodel(type, version, id, new, view_hash, deserialize_context: deserialize_context)

        deserialize_members_from_view(viewmodel, view_hash, references: references, deserialize_context: deserialize_context)

        viewmodel.validate!

        viewmodel
      end
    end

    def deserialize_members_from_view(viewmodel, view_hash, references:, deserialize_context:)
      deserialize_context.visible!(viewmodel)

      if (bad_attrs = view_hash.keys - self.member_names).present?
        raise ViewModel::DeserializationError.new("Illegal attribute(s) #{bad_attrs.inspect} for viewmodel #{self.view_name}",
                                                  viewmodel.blame_reference)
      end

      initial_editability = deserialize_context.initial_editability(viewmodel)

      _members.each do |attr, _|
        if view_hash.has_key?(attr)
          viewmodel.public_send("deserialize_#{attr}", view_hash[attr], references: references, deserialize_context: deserialize_context)
        end
      end

      changes = viewmodel.changes

      if changes.new? || changes.changed_attributes.present?
        deserialize_context.editable!(viewmodel,
                                      initial_editability: initial_editability,
                                      changes:             changes)
      end

      viewmodel.clear_changes!
    end

    def resolve_viewmodel(type, version, id, new, view_hash, deserialize_context:)
      self.for_new_model
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

    private

    # Set the record type to be wrapped by this viewmodel
    def model_class_name=(name)
      type = name.to_s.camelize.safe_constantize
      raise ArgumentError.new("Could not find model class '#{name}'") if type.nil?
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

  attr_reader :changed_attributes, :new_model

  alias :new_model? :new_model

  def initialize(model)
    unless model.is_a?(model_class)
      raise ArgumentError.new("'#{model.inspect}' is not an instance of #{model_class.name}")
    end

    super(model)

    @new_model          = false
    @changed_attributes = []
  end

  def self.for_new_model(*model_args)
    self.new(model_class.new(*model_args)).tap { |v| v.model_is_new! }
  end

  def serialize_view(json, serialize_context: self.class.new_serialize_context)
    json.set!(ViewModel::ID_ATTRIBUTE, model.id) if model.respond_to?(:id)
    json.set!(ViewModel::TYPE_ATTRIBUTE, self.view_name)
    json.set!(ViewModel::VERSION_ATTRIBUTE, self.class.schema_version)

    serialize_members(json, serialize_context: serialize_context)
  end

  def serialize_members(json, serialize_context:)
    self.class._members.each do |member_name, member_data|
      next unless serialize_context.includes_member?(member_name, !member_data.optional?)
      self.public_send("serialize_#{member_name}", json, serialize_context: serialize_context)
    end
  end

  # Check that the model backing this view is consistent, for example by calling
  # AR validations. Default implementation handles ActiveModel::Validations, may
  # be overridden by subclasses for other types of validation. Must raise
  # DeserializationError::Validation if invalid.
  def validate!
    if model_class < ActiveModel::Validations && !model.valid?
      raise ViewModel::DeserializationError::Validation.new(
              "Validation failed: " + model.errors.full_messages.join(", "),
              self.blame_reference,
              model.errors.messages)
    end
  end

  def model_is_new!
    @new_model = true
  end

  def attribute_changed!(attr_name)
    @changed_attributes << attr_name.to_s
  end

  def clear_changed_attributes!
    @changed_attributes = []
  end

  def changes
    ViewModel::Changes.new(
      new:                new_model?,
      changed_attributes: changed_attributes)
  end

  def clear_changes!
    @new_model          = false
    @changed_attributes = []
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
    attr = attr_data.name

    value = model.public_send(attr)

    if attr_data.using_viewmodel? && !value.nil?
      vm_type = attr_data.attribute_viewmodel
      if attr_data.array?
        value = value.map { |v| vm_type.new(v) }
      else
        value = vm_type.new(value)
      end
    end

    value
  end

  def _serialize_attribute(attr_data, json, serialize_context:)
    attr = attr_data.name

    value = self.public_send(attr)

    json.set! attr do
      serialize_context = serialize_context.for_child(self, association_name: attr.to_s) if attr_data.using_viewmodel?
      self.class.serialize(value, json, serialize_context: serialize_context)
    end
  end

  def _deserialize_attribute(attr_data, serialized_value, references:, deserialize_context:)
    attr = attr_data.name

    if attr_data.using_viewmodel? && !serialized_value.nil?
      vm_type = attr_data.attribute_viewmodel
      ctx = deserialize_context.for_child(self)
      if attr_data.array?
        expect_type!(attr, Array, serialized_value)
        value = serialized_value.map { |v| vm_type.deserialize_from_view(v, references: references, deserialize_context: ctx) }
      else
        value = vm_type.deserialize_from_view(serialized_value, references: references, deserialize_context: ctx)
      end
    else
      value = serialized_value
    end

    # Detect changes with ==. In the case of `using_viewmodel?`, this compares viewmodels or arrays of viewmodels.
    if value != self.public_send(attr)
      if attr_data.read_only? && !(attr_data.write_once? && new_model?)
        raise ViewModel::DeserializationError.new("Cannot edit read only attribute: #{attr}", self.blame_reference)
      end

      attribute_changed!(attr)

      if attr_data.using_viewmodel? && !value.nil?
        # Extract model from target viewmodel to attach to model
        if attr_data.array?
          value = value.map(&:model)
        else
          value = value.model
        end
      end

      model.public_send("#{attr}=", value)
    end
  end

  # Helper for type-checking input in hand-rolled deserialization: raises
  # DeserializationError unless the serialized value is of the provided type.
  def expect_type!(attribute, type, serialized_value)
    unless serialized_value.is_a?(type)
      raise DeserializationError.new("Expected '#{attribute}' to be '#{type.name}', was '#{serialized_value.class}'", blame_reference)
    end
  end
end
