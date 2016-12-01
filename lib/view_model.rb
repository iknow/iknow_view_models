# A ViewModel encapsulates a particular aggregation of data calculated via the
# underlying models and provides a means of serializing it into views.
require 'jbuilder'
require 'deep_preloader'

class ViewModel
  REFERENCE_ATTRIBUTE = "_ref"
  ID_ATTRIBUTE        = "id"
  TYPE_ATTRIBUTE      = "_type"
  VERSION_ATTRIBUTE   = "_version"
  NEW_ATTRIBUTE       = "_new"

  class << self
    attr_accessor :_attributes
    attr_accessor :schema_version
    attr_reader   :view_aliases

    def inherited(subclass)
      subclass.initialize_as_viewmodel
    end

    def initialize_as_viewmodel
      @_attributes    = []
      @schema_version = 1
      @debug_name     = nil
      @view_aliases   = []
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

    def view_names
      [view_name, *view_aliases]
    end

    def add_view_alias(as)
      view_aliases << as
    end

    def debug_name=(name)
      @debug_name = name
    end

    def debug_name
      @debug_name || view_name
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

    # An abstract viewmodel may want to define attributes to be shared by their
    # subclasses. Redefine `_attributes` to close over the current class's
    # _attributes and ignore children.
    def lock_attribute_inheritance
      _attributes.tap do |attrs|
        define_singleton_method(:_attributes) { attrs }
        attrs.freeze
      end
    end

    # In deserialization, verify and extract metadata from a provided hash.
    def extract_viewmodel_metadata(hash)
      ViewModel::Schemas.verify_schema!(ViewModel::Schemas::VIEWMODEL_UPDATE, hash)
      id             = hash.delete(ViewModel::ID_ATTRIBUTE)
      type_name      = hash.delete(ViewModel::TYPE_ATTRIBUTE)
      schema_version = hash.delete(ViewModel::VERSION_ATTRIBUTE)
      new            = hash.delete(ViewModel::NEW_ATTRIBUTE) { false }
      return type_name, schema_version, id, new
    end

    def extract_reference_only_metadata(hash)
      ViewModel::Schemas.verify_schema!(ViewModel::Schemas::VIEWMODEL_UPDATE, hash)
      id             = hash.delete(ViewModel::ID_ATTRIBUTE)
      type_name      = hash.delete(ViewModel::TYPE_ATTRIBUTE)
      return type_name, id
    end

    def extract_reference_metadata(hash)
      ViewModel::Schemas.verify_schema!(ViewModel::Schemas::VIEWMODEL_REFERENCE, hash)
      hash.delete(ViewModel::REFERENCE_ATTRIBUTE)
    end

    def is_update_hash?(hash)
      ViewModel::Schemas.verify_schema!(ViewModel::Schemas::VIEWMODEL_UPDATE, hash)
      hash.has_key?(ViewModel::ID_ATTRIBUTE) &&
        !hash.fetch(ViewModel::ActiveRecord::NEW_ATTRIBUTE, false)
    end

    # If this viewmodel represents an AR model, what associations does it make
    # use of? Returns a includes spec appropriate for DeepPreloader, either as
    # AR-style nested hashes or DeepPreloader::Spec.
    def eager_includes(serialize_context: new_serialize_context, include_shared: true)
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
    def deserialize_from_view(hash_data, references: {}, deserialize_context: new_deserialize_context)
      raise DeserializationError.new("Deserialization not defined for '#{self.name}'", self.blame_reference)
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

    def accepts_schema_version?(schema_version)
      schema_version == self.schema_version
    end

    def preload_for_serialization(viewmodels, serialize_context: new_serialize_context, include_shared: true, lock: nil)
      Array.wrap(viewmodels).group_by(&:class).each do |type, views|
        DeepPreloader.preload(views.map(&:model),
                              type.eager_includes(serialize_context: serialize_context, include_shared: include_shared),
                              lock: lock)
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
    serialize_context.visible!(self)
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

  def id
    model.id if model.respond_to?(:id)
  end

  def to_reference
    ViewModel::Reference.new(self.class, self.id)
  end

  # Delegate view_name to class in most cases. Polymorphic views may wish to
  # override this to select a specific alias.
  def view_name
    self.class.view_name
  end

  # When deserializing, if an error occurs within this viewmodel, what viewmodel
  # is reported as to blame. Can be overridden for example when a viewmodel is
  # merged with its parent.
  def blame_reference
    to_reference
  end

  def preload_for_serialization(lock: nil, serialize_context: self.class.new_serialize_context)
    ViewModel.preload_for_serialization([self], lock: lock, serialize_context: serialize_context)
  end

  def ==(other_view)
    other_view.class == self.class && self.class._attributes.all? do |attr|
      other_view.send(attr) == self.send(attr)
    end
  end

  alias :eql? :==

  def hash
    self.class._attributes.map { |attr| self.send(attr) }.hash
  end

end

require 'view_model/utils'
require 'view_model/error'
require 'view_model/access_control'
require 'view_model/deserialization_error'
require 'view_model/serialization_error'
require 'view_model/registry'
require 'view_model/references'
require 'view_model/reference'
require 'view_model/serialize_context'
require 'view_model/deserialize_context'
require 'view_model/changes'
