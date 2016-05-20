# A ViewModel encapsulates a particular aggregation of data calculated via the
# underlying models and provides a means of serializing it into views.
require 'jbuilder'

class ViewModel
  class DeserializationError < StandardError
    class Permissions < DeserializationError; end
  end

  class SerializationError < StandardError
    class Permissions < SerializationError; end
  end

  # A bucket for configuration, used for serializing and deserializing.
  class References
    delegate :each, :size, to: :@value_by_ref

    def initialize
      @last_ref = 0
      @ref_by_value = {}
      @value_by_ref = {}
    end

    def has_references?
      @ref_by_value.present?
    end

    # Takes a reference to a thing that is to be shared, and returns the id
    # under which the data is stored. If the data is not present, will compute
    # it by calling the given block.
    def add_reference(value)
      if (ref = @ref_by_value[value]).present?
        ref
      else
        ref = new_ref!
        @ref_by_value[value] = ref
        @value_by_ref[ref] = value
        ref
      end
    end

    private

    def new_ref!
      'ref%06d' % (@last_ref += 1)
    end
  end

  class SerializeContext
    delegate :add_reference, :has_references?, to: :@references
    attr_accessor :include

    def stringify_includes(includes)
      case includes
      when Array
        includes.map(&:to_s)
      when Hash
        hash.each_with_object({}) do |(k,v), new_includes|
          new_includes[k.to_s] = stringify_includes(v)
        end
      when nil
        nil
      else
        includes.to_s
      end
    end

    def initialize(include: nil)
      @references = References.new

      self.include = stringify_includes(include)
    end

    def for_association(association_name)
      # Shallow clone aliases @references; association traversal must not
      # "change" the context, otherwise references will be lost.
      self.dup.tap do |copy|
        copy.include = include.is_a?(Hash) ? include[association_name] : nil
      end
    end

    def includes_association?(association_name)
      association_name = association_name.to_s

      case include
      when Array
        include.include?(association_name)
      when Hash
        include.has_key?(association_name)
      when nil
        false
      else
        include.to_s == association_name
      end
    end


    def serialize_references(json)
      seen = Set.new
      while seen.size != @references.size
        @references.each do |ref, value|
          if seen.add?(ref)
            json.set!(ref) do
              ViewModel.serialize(value, json, serialize_context: self)
            end
          end
        end
      end
    end

    def serialize_references_to_hash
      Jbuilder.new { |json| serialize_references(json) }.attributes!
    end
  end

  class DeserializeContext
    def initialize(*)
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
    def eager_includes(serialize_context: new_serialize_context)
      []
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

    def serialize_to_hash(viewmodel, serialize_context: new_serialize_context)
      Jbuilder.new { |json| serialize(viewmodel, json, serialize_context: serialize_context) }.attributes!
    end

    # Rebuild this viewmodel from a serialized hash. Must be defined in subclasses.
    def deserialize_from_view(hash_data, deserialize_context: new_deserialize_context)
      raise DeserializationError.new("Deserialization not defined for '#{self.name}'")
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

  def preload_model(serialize_context: self.class.new_serialize_context)
    ActiveRecord::Associations::Preloader.new(Array.wrap(self.model),
                                              self.class.eager_includes(serialize_context: serialize_context)).run
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
      raise DeserializationError::Permissions.new("Attempt to edit forbidden viewmodel '#{self.class.name}'")
    end
  end

end
