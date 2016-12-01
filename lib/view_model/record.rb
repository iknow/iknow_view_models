require 'view_model/schemas'

# Abstract ViewModel type for serializing a subset of attributes from a record.
# A record viewmodel wraps a single underlying model, exposing a fixed set of
# real or calculated attributes.
class ViewModel::Record < ViewModel
  attribute :model

  require 'view_model/record/attribute_data'

  class << self
    attr_reader :_members
    attr_accessor :abstract_class, :unregistered

    def inherited(subclass)
      super
      # copy ViewModel setup
      subclass._attributes = self._attributes

      subclass.initialize_members
      ViewModel::Registry.register(subclass)
    end

    def initialize_members
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
    def attribute(attr, read_only: false, using: nil, optional: false)
      _members[attr.to_s] = AttributeData.new(using, optional, read_only)

      @generated_accessor_module.module_eval do
        define_method attr do
          val = model.public_send(attr)
          val = using.new(val) if using && !val.nil?
          val
        end

        define_method "serialize_#{attr}" do |json, serialize_context: self.class.new_serialize_context|
          value = self.public_send(attr)
          json.set! attr do
            serialize_context = serialize_context.for_association(attr.to_s) if using.present?
            self.class.serialize(value, json, serialize_context: serialize_context)
          end
        end

        if read_only
          define_method "deserialize_#{attr}" do |value, deserialize_context: self.class.new_deserialize_context|
            value = using.deserialize_from_view(value, deserialize_context: deserialize_context.for_child(self)) if using && !value.nil?
            if value != self.public_send(attr)
              raise ViewModel::DeserializationError.new("Cannot edit read only attribute: #{attr}", self.blame_reference)
            end
          end
        else
          define_method "deserialize_#{attr}" do |value, deserialize_context: self.class.new_deserialize_context|
            value = using.deserialize_from_view(value, deserialize_context: deserialize_context.for_child(self)).model if using && !value.nil?
            model.public_send("#{attr}=", value)
          end
        end
      end
    end

    def deserialize_from_view(view_hashes, references: {}, deserialize_context: new_deserialize_context)
      return_array = view_hashes.is_a?(Array)

      viewmodels = Array.wrap(view_hashes).map do |view_hash|
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

        viewmodel
      end

      return_array ? viewmodels : viewmodels.first
    end

    def deserialize_members_from_view(viewmodel, view_hash, references:, deserialize_context:)
      viewmodel.visible!(context: deserialize_context)

      if view_hash.present?
        # we don't necessarily have a model that can tell us after the fact
        # whether we changed anything, so need to edit check if any attributes
        # are provided. This doesn't allow for idempotent uploads with partial
        # privileges, as offered by VM::AR.
        viewmodel.editable!(deserialize_context: deserialize_context)
      end

      if (bad_attrs = view_hash.keys - self.member_names).present?
        raise ViewModel::DeserializationError.new("Illegal attribute(s) #{bad_attrs.inspect} for viewmodel #{self.view_name}",
                                                  viewmodel.blame_reference)
      end

      _members.each do |attr, _|
        if view_hash.has_key?(attr)
          viewmodel.public_send("deserialize_#{attr}", view_hash[attr], deserialize_context: deserialize_context)
        end
      end
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

  def initialize(model)
    unless model.is_a?(model_class)
      raise ArgumentError.new("'#{model.inspect}' is not an instance of #{model_class.name}")
    end

    super(model)
  end

  def self.for_new_model(id: nil)
    self.new(model_class.new(id: id))
  end

  def serialize_view(json, serialize_context: self.class.new_serialize_context)
    json.set!(ViewModel::ID_ATTRIBUTE, model.id) if model.respond_to?(:id)
    json.set!(ViewModel::TYPE_ATTRIBUTE, self.class.view_name)
    json.set!(ViewModel::VERSION_ATTRIBUTE, self.class.schema_version)

    serialize_members(json, serialize_context: serialize_context)
  end

  def serialize_members(json, serialize_context:)
    self.class._members.each do |member_name, member_data|
      next unless serialize_context.includes_member?(member_name, !member_data.optional?)
      self.public_send("serialize_#{member_name}", json, serialize_context: serialize_context)
    end
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
end
