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
  # :model, and used by `serialize_child` for chaining ViewModel serialization.
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

  # ViewModel can serialize ViewModels, and Arrays and Hashes of ViewModels.
  def self.serialize(target, json, options = {})
    case target
    when ViewModel
      target.serialize_view(json, options)
    when Array
      json.array! target do |elt|
        serialize(elt, json, options)
      end
    when Hash
      target.each do |k, v|
        json.set! k do
          serialize(v, json, options)
        end
      end
    end
  end

  def self.serialize_to_hash(viewmodel)
    Jbuilder.new { |json| serialize(viewmodel, json, {}) }.attributes!
  end

  # default serialize_view: visit child attributes with serialize
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

  def serialize_child(child_relation, child_model, json, options = {})
    child = self.model.public_send(child_relation)
    child_model.new(child).serialize_view(json, options) if child
  end

end
