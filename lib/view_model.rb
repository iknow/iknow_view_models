# A ViewModel encapsulates a particular aggregation of data calculated via the
# underlying models and provides a means of serializing it into views.
require 'jbuilder'

class ViewModel
  class DeserializationError < StandardError; end
  class SerializationError < StandardError; end

  # A bucket for configuration, used for serializing and deserializing.
  class Context
    attr_accessor :prune, :include

    def for_association(association_name)
      copy = self.dup
      copy.prune = prune.try(:[], association_name)
      copy
    end
  end

  class << self
    attr_accessor :_attributes

    def inherited(subclass)
      subclass._attributes = []
    end

    # ViewModels are typically going to be pretty simple structures. Make it a
    # bit easier to define them: attributes specified this way are given
    # accessors and assigned in order by the default constructor.
    def attributes(*attrs)
      attrs.each { |attr| attribute(attr) }
    end

    def attribute(attr)
      unless attr.is_a?(Symbol)
        raise ArgumentError.new("ViewModel attributes must be symbols")
      end

      attr_accessor attr
      _attributes << attr
    end

    # Provide compatibility with previous ViewModel creation interface.
    def self.with_attrs(*attrs)
      Class.new(self) do
        attributes(*attrs)
      end
    end

    # If this viewmodel represents an AR model, what associations does it make
    # use of?
    def eager_includes(view_context: default_context)
      []
    end

    # ViewModel can serialize ViewModels, Arrays and Hashes of ViewModels, and
    # relies on Jbuilder#merge! for other values (e.g. primitives).
    def serialize(target, json, view_context: Context.new)
      case target
      when ViewModel
        target.serialize(json, view_context: view_context)
      when Array
        json.array! target do |elt|
          serialize(elt, json, view_context: view_context)
        end
      when Hash, Struct
        target.each_pair do |key, value|
          json.set! key do
            serialize(value, json, view_context: view_context)
          end
        end
      else
        json.merge! target
      end
    end

    def serialize_to_hash(viewmodel, view_context: default_context)
      Jbuilder.new { |json| serialize(viewmodel, json, view_context: view_context) }.attributes!
    end

    # Rebuild this viewmodel from a serialized hash. Must be defined in subclasses.
    def deserialize_from_view(hash_data, view_context: default_context)
      raise DeserializationError.new("Deserialization not defined for '#{self.name}'")
    end

    def default_context
      context_class.new
    end

    def context_class
      ViewModel::Context
    end
  end

  delegate :default_context, to: :class

  def initialize(*args)
    self.class._attributes.each_with_index do |attr, idx|
      self.public_send(:"#{attr}=", args[idx])
    end
  end

  # Serialize this viewmodel to a jBuilder by calling serialize_view. May be
  # overridden in subclasses to (for example) implement caching.
  def serialize(json, view_context: default_context)
    visible!(view_context: view_context)
    serialize_view(json, view_context: view_context)
  end

  def to_hash(view_context: default_context)
    Jbuilder.new { |json| serialize(json, view_context: view_context) }.attributes!
  end

  # Render this viewmodel to a jBuilder. Usually overridden in subclasses.
  # Default implementation visits each attribute with Viewmodel.serialize.
  def serialize_view(json, view_context: default_context)
    json.set!("_type", self.class.name)
    self.class._attributes.each do |attr|
      json.set! attr do
        ViewModel.serialize(self.send(attr), json, view_context: view_context)
      end
    end
  end

  # ViewModels are often used to serialize ActiveRecord models. For convenience,
  # if necessary we assume that the wrapped model is the first attribute. To
  # change this, override this method.
  def model
    self.public_send(self.class._attributes.first)
  end

  def preload_model(view_context: default_context)
    ActiveRecord::Associations::Preloader.new(Array.wrap(self.model), self.class.eager_includes(view_context: view_context)).run
  end

  def visible?(view_context: default_context)
    true
  end

  def visible!(view_context: default_context)
    unless visible?(view_context: view_context)
      raise SerializationError.new("Attempt to view forbidden viewmodel '#{self.class.name}'")
    end
  end

  def editable?(view_context: default_context)
    visible?(view_context: view_context)
  end

  def editable!(view_context: default_context)
    unless editable?(view_context: view_context)
      raise DeserializationError.new("Attempt to edit forbidden viewmodel '#{self.class.name}'")
    end
  end

end
