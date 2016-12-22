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

    def inherited(subclass)
      subclass.initialize_as_viewmodel
    end

    def initialize_as_viewmodel
      @_attributes     = []
      @schema_version = 1
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

    # An abstract viewmodel may want to define attributes to be shared by their
    # subclasses. Redefine `_attributes` to close over the current class's
    # _attributes and ignore children.
    def lock_attribute_inheritance
      _attributes.tap do |attrs|
        define_singleton_method(:_attributes) { attrs }
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

  def id
    model.id if model.respond_to?(:id)
  end

  def to_reference
    ViewModel::Reference.new(self.class, self.id)
  end

  # When deserializing, if an error occurs within this viewmodel, what viewmodel
  # is reported as to blame. Can be overridden for example when a viewmodel is
  # merged with its parent.
  def blame_reference
    to_reference
  end

  def preload_for_serialization(serialize_context: self.class.new_serialize_context)
    ViewModel.preload_for_serialization([self], serialize_context: serialize_context)
  end

  attr_writer :access_check_error

  def visible?(context: self.class.new_serialize_context)
    true
  end

  def visible!(context: self.class.new_serialize_context)
    self.access_check_error = nil
    unless visible?(context: context)
      raise case
            when @access_check_error
              @access_check_error
            when context.is_a?(DeserializeContext)
              DeserializationError::Permissions.new("Attempt to deserialize into forbidden viewmodel '#{self.class.view_name}'",
                                                    self.blame_reference)
            else
              SerializationError::Permissions.new("Attempt to serialize forbidden viewmodel '#{self.class.view_name}'")
            end
    end
  end

  def editable?(deserialize_context: self.class.new_deserialize_context, changed_associations:, deleted:)
    visible?(context: deserialize_context)
  end

  def editable!(deserialize_context: self.class.new_deserialize_context, changed_associations: [], deleted: false)
    self.access_check_error = nil
    unless editable?(deserialize_context: deserialize_context, changed_associations: changed_associations, deleted: deleted)
      err = @access_check_error ||
            DeserializationError::Permissions.new("Attempt to edit forbidden viewmodel '#{self.class.view_name}'",
                                                  self.blame_reference)
      raise err
    end
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

require 'view_model/error'
require 'view_model/deserialization_error'
require 'view_model/serialization_error'
require 'view_model/registry'
require 'view_model/references'
require 'view_model/reference'
require 'view_model/serialize_context'
require 'view_model/deserialize_context'
