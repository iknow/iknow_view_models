# A ViewModel encapsulates a particular aggregation of data calculated via the
# underlying models and provides a means of serializing it into views.
require 'jbuilder'

class ViewModel
  # If this viewmodel represents an AR model, what associations does it make use
  # of?
  def self.eager_includes
    []
  end

  # ViewModels are typically going to be pretty simple structures. Make it a bit
  # easier to define them: this helper creates a class extending ViewModel with
  # the provided attributes and a constructor which assigns them in order. The
  # first attribute is considered slightly special: it's aliased by the method
  # :model, and used by Cerego.com's `serialize_child` for chaining ViewModel
  # serialization.
  def self.with_attrs(*attrs)
    attrs.freeze
    init = lambda do |*args|
      attrs.each_with_index do |attr, idx|
        instance_variable_set("@#{attr}", args[idx])
      end
    end
    attr_names = lambda { attrs }
    Class.new(self) do
      attr_accessor *attrs
      alias_method(:model, attrs.first) unless method_defined?(:model)
      define_method :initialize, init
      define_method :attr_names, attr_names
    end
  end

  # ViewModel can serialize ViewModels, Arrays and Hashes of ViewModels, and
  # relies on Jbuilder#merge! for anything else.
  def self.serialize(target, json, options = {})
    case target
    when ViewModel
      target.serialize(json, options)
    when Array
      json.array! target do |elt|
        serialize(elt, json, options)
      end
    when Hash
      target.each do |k, v|
        if is_primitive?(v)
          json.set! k, v
        else
          json.set! k do
            serialize(v, json, options)
          end
        end
      end
    else
      json.merge! target
    end
  end

  def self.serialize_to_hash(viewmodel, options = {})
    Jbuilder.new { |json| serialize(viewmodel, json, options) }.attributes!
  end

  # Serialize this viewmodel to a jBuilder by calling serialize_view. May be
  # overridden in subclasses to (for example) implement caching.
  def serialize(json, options = {})
    serialize_view(json, options)
  end

  def to_hash(options = {})
    Jbuilder.new { |json| serialize(json, options) }.attributes!
  end

  # Render this viewmodel to a jBuilder. Usually overridden in subclasses.
  # Default implementation visits each attribute with Viewmodel.serialize.
  def serialize_view(json, options = {})
    attr_names.each do |attr|
      attr_value = self.send(attr)
      case attr_value
      when ViewModel, Array, Hash
        json.set! attr do
          ViewModel.serialize(attr_value, json, options)
        end
      else
        json.set! attr, attr_value
      end
    end
  end

  private

  def self.is_primitive?(object)
    case object
    when Integer, String
      true
    when Array
      is_primitive?(object.first)
    end
  end

end
