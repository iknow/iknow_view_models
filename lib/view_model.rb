# A ViewModel encapsulates a particular aggregation of data calculated via the
# underlying models and provides a means of serializing it into views.
require 'jbuilder'

class ViewModel
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
    def eager_includes
      []
    end

    # ViewModel can serialize ViewModels, Arrays and Hashes of ViewModels, and
    # relies on Jbuilder#merge! for other values (e.g. primitives).
    def serialize(target, json, **options)
      case target
      when ViewModel
        target.serialize(json, **options)
      when Array
        json.array! target do |elt|
          serialize(elt, json, **options)
        end
      when Hash, Struct
        target.each_pair do |key, value|
          json.set! key do
            serialize(value, json, **options)
          end
        end
      else
        json.merge! target
      end
    end

    def serialize_to_hash(viewmodel, **options)
      Jbuilder.new { |json| serialize(viewmodel, json, **options) }.attributes!
    end
  end

  def initialize(*args)
    self.class._attributes.each_with_index do |attr, idx|
      self.public_send(:"#{attr}=", args[idx])
    end
  end

  # Serialize this viewmodel to a jBuilder by calling serialize_view. May be
  # overridden in subclasses to (for example) implement caching.
  def serialize(json, **options)
    serialize_view(json, **options)
  end

  def to_hash(**options)
    Jbuilder.new { |json| serialize(json, **options) }.attributes!
  end

  # Render this viewmodel to a jBuilder. Usually overridden in subclasses.
  # Default implementation visits each attribute with Viewmodel.serialize.
  def serialize_view(json, **options)
    self.class._attributes.each do |attr|
      json.set! attr do
        ViewModel.serialize(self.send(attr), json, **options)
      end
    end
  end

  # ViewModels are often used to serialize ActiveRecord models. For convenience,
  # if necessary we assume that the wrapped model is the first attribute. To
  # change this, override this method.
  def model
    self.public_send(self.class._attributes.first)
  end

  def preload_model
    ActiveRecord::Associations::Preloader.new(Array.wrap(self.model), self.class.eager_includes).run
  end
end
