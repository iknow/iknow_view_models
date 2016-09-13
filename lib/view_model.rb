# A ViewModel encapsulates a particular aggregation of data calculated via the
# underlying models and provides a means of serializing it into views.
require 'jbuilder'
require 'deep_preloader'

class ViewModel
  REFERENCE_ATTRIBUTE = "_ref"
  ID_ATTRIBUTE        = "id"
  TYPE_ATTRIBUTE      = "_type"

  require 'view_model/deserialization_error'
  require 'view_model/serialization_error'
  require 'view_model/references'
  require 'view_model/reference'
  require 'view_model/serialize_context'
  require 'view_model/deserialize_context'

  class << self
    attr_accessor :_attributes

    def inherited(subclass)
      subclass._attributes = []
    end

    def view_name
      @view_name ||=
        begin
          # try to auto-detect based on class name
          match = /(.*)View$/.match(self.name)
          raise ArgumentError.new("Could not auto-determine ViewModel name from class name '#{self.name}'") if match.nil?
          match[1]
        end
    end

    def view_name=(name)
      @view_name = name
    end

    # ViewModels are typically going to be pretty simple structures. Make it a
    # bit easier to define them: attributes specified this way are given
    # accessors and assigned in order by the default constructor.
    def attributes(*attrs, **args)
      attrs.each { |attr| attribute(attr, **args) }
    end

    def attribute(attr, **args)
      unless attr.is_a?(Symbol)
        raise ArgumentError.new("ViewModel attributes must be symbols")
      end

      attr_accessor attr
      _attributes << attr
    end

    # If this viewmodel represents an AR model, what associations does it make
    # use of? Returns a includes spec appropriate for DeepPreloader, either as
    # AR-style nested hashes or DeepPreloader::Spec.
    def eager_includes(serialize_context: new_serialize_context)
      {}
    end

    # ViewModel can serialize ViewModels, Arrays and Hashes of ViewModels, and
    # relies on Jbuilder#merge! for other values (e.g. primitives).
    def serialize(target, json, serialize_context: new_serialize_context)
      case target
      when ViewModel
        target.serialize(json, serialize_context: serialize_context)
      when Array
        json.array! target do |elt|
          serialize(elt, json, serialize_context: serialize_context)
        end
      when Hash, Struct
        target.each_pair do |key, value|
          json.set! key do
            serialize(value, json, serialize_context: serialize_context)
          end
        end
      else
        json.merge! target
      end
    end

    def serialize_as_reference(target, json, serialize_context: new_serialize_context)
      if serialize_context.flatten_references
        serialize(target, json, serialize_context: serialize_context)
      else
        ref = serialize_context.add_reference(target)
        json.set!(REFERENCE_ATTRIBUTE, ref)
      end
    end

    def serialize_to_hash(viewmodel, serialize_context: new_serialize_context)
      Jbuilder.new { |json| serialize(viewmodel, json, serialize_context: serialize_context) }.attributes!
    end

    # Rebuild this viewmodel from a serialized hash. Must be defined in subclasses.
    def deserialize_from_view(hash_data, deserialize_context: new_deserialize_context)
      raise DeserializationError.new("Deserialization not defined for '#{self.name}'", self.to_reference)
    end

    def serialize_context_class
      ViewModel::SerializeContext
    end

    def new_serialize_context(*args)
      serialize_context_class.new(*args)
    end

    def deserialize_context_class
      ViewModel::DeserializeContext
    end

    def new_deserialize_context(*args)
      deserialize_context_class.new(*args)
    end


    def preload_for_serialization(viewmodels, serialize_context: new_serialize_context)
      Array.wrap(viewmodels).group_by(&:class).each do |type, views|
        DeepPreloader.preload(views.map(&:model),
                              type.eager_includes(serialize_context: serialize_context))
      end
    end
  end

  def initialize(*args)
    self.class._attributes.each_with_index do |attr, idx|
      self.public_send(:"#{attr}=", args[idx])
    end
  end

  # Serialize this viewmodel to a jBuilder by calling serialize_view. May be
  # overridden in subclasses to (for example) implement caching.
  def serialize(json, serialize_context: self.class.new_serialize_context)
    visible!(context: serialize_context)
    serialize_view(json, serialize_context: serialize_context)
  end

  def to_hash(serialize_context: self.class.new_serialize_context)
    Jbuilder.new { |json| serialize(json, serialize_context: serialize_context) }.attributes!
  end

  # Render this viewmodel to a jBuilder. Usually overridden in subclasses.
  # Default implementation visits each attribute with Viewmodel.serialize.
  def serialize_view(json, serialize_context: self.class.new_serialize_context)
    self.class._attributes.each do |attr|
      json.set! attr do
        ViewModel.serialize(self.send(attr), json, serialize_context: serialize_context)
      end
    end
  end

  # ViewModels are often used to serialize ActiveRecord models. For convenience,
  # if necessary we assume that the wrapped model is the first attribute. To
  # change this, override this method.
  def model
    self.public_send(self.class._attributes.first)
  end

  def to_reference
    ViewModel::Reference.new(self.class, self.try(&:id))
  end

  def preload_for_serialization(serialize_context: self.class.new_serialize_context)
    ViewModel.preload_for_serialization([self], serialize_context: serialize_context)
  end

  def visible?(context: self.class.new_serialize_context)
    true
  end

  def visible!(context: self.class.new_serialize_context)
    unless visible?(context: context)
      raise SerializationError::Permissions.new("Attempt to view forbidden viewmodel '#{self.class.name}'")
    end
  end

  def editable?(deserialize_context: self.class.new_deserialize_context)
    visible?(context: deserialize_context)
  end

  def editable!(deserialize_context: self.class.new_deserialize_context)
    unless editable?(deserialize_context: deserialize_context)
      raise DeserializationError::Permissions.new("Attempt to edit forbidden viewmodel '#{self.class.name}'", self.to_reference)
    end
  end

end
