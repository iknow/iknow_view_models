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
      @_attributes    = []
      @schema_version = 1
      @debug_name     = nil
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

    def preload_for_serialization(viewmodels, serialize_context: new_serialize_context, include_shared: true)
      Array.wrap(viewmodels).group_by(&:class).each do |type, views|
        DeepPreloader.preload(views.map(&:model),
                              type.eager_includes(serialize_context: serialize_context, include_shared: include_shared))
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

  def has_access_check_error?
    @access_check_error.present?
  end

  # Check that the user is permitted to view the record in its current state, in
  # the given context. To be overridden by viewmodel implementation.
  def visible?(context: self.class.new_serialize_context)
    true
  end

  # Editable checks during deserialization are always a combination of
  # `editable?` and `valid_edit?`, which express the following separate
  # properties:

  # Check that the record is eligible to be changed in its current state, in the
  # given context. During deserialization, this must be called before any edits
  # have taken place (thus checking against the initial state of the viewmodel),
  # and if found false, an error must be raised if an edit is later attempted.
  # To be overridden by viewmodel implementations.
  def editable?(deserialize_context: self.class.new_deserialize_context)
    true
  end

  # Check that the attempted changes to this record are permitted in the given
  # context. During deserialization, this must be called once all edits have
  # been attempted. To be overridden by viewmodel implementations.
  def valid_edit?(deserialize_context: self.class.new_deserialize_context, changes:)
    true
  end

  # During deserialization, returns true if the viewmodel was found `editable?`
  # before any changes were attempted. Takes a viewmodel on which to optionally
  # set the access check error, which can be used when delegating to a parent
  # view's editability.
  def was_editable?(error_view:)
    unless instance_variable_defined?(:@initial_editable_state) && @initial_editable_state
      raise DeserializationError.new("Attempted to call `was_editable?` outside deserialization.",
                                     self.blame_reference)
    end
    editable, err = @initial_editable_state
    error_view.access_check_error = err if err
    editable
  end

  # Implementations of serialization and deserialization should call this
  # whenever a viewmodel is visited during serialization or deserialization.
  def visible!(context: self.class.new_serialize_context)
    self.access_check_error = nil
    unless visible?(context: context)
      raise_access_check_error do
        if context.is_a?(DeserializeContext)
          DeserializationError::Permissions.new("Attempt to deserialize into forbidden viewmodel '#{self.class.view_name}'",
                                                self.blame_reference)
        else
          SerializationError::Permissions.new("Attempt to serialize forbidden viewmodel '#{self.class.view_name}'")
        end
      end
    end
  end

  # Implementations of deserialization that may or may not make changes to the
  # viewmodel should call this on the viewmodel to save the initial `editable?`
  # value and optional exception before attempting to apply their changes.
  def save_editable!(deserialize_context: self.class.new_deserialize_context)
    val = editable?(deserialize_context: deserialize_context)
    @initial_editable_state = [val, @access_check_error]
    self.access_check_error = nil
  end

  # Implementations of deserialization that have called `save_editable!` to
  # cache their initial editable check should call this after they know that a
  # change will be made.
  def was_editable!
    self.access_check_error = nil
    unless was_editable?(error_view: self)
      raise_access_check_error do
        DeserializationError::Permissions.new(
          "Attempt to edit forbidden viewmodel '#{self.class.view_name}'",
          self.blame_reference)
      end
    end
    @initial_editable_state = nil
  end

  # Implementations of deserialization that know in advance that they will make
  # changes to the viewmodel may call this immediately rather than
  # `save_editable!` followed by `was_editable!`.
  def editable!(deserialize_context: self.class.new_deserialize_context)
    self.access_check_error = nil
    if instance_variable_defined?(:@initial_editable_state) && @initial_editable_state
      raise DeserializationError.new("Attempted to call `editable!` during deserialization: use `was_editable!`.", self.blame_reference)
    end
    unless editable?(deserialize_context: deserialize_context)
      raise_access_check_error do
        DeserializationError::Permissions.new(
          "Attempt to edit forbidden viewmodel '#{self.class.view_name}'",
          self.blame_reference)
      end
    end
  end

  # Implementations of deserialization should call this once they have made all
  # changes that will be performed to the viewmodel.
  def valid_edit!(deserialize_context: self.class.new_deserialize_context, changes:)
    self.access_check_error = nil
    unless valid_edit?(deserialize_context: deserialize_context, changes: changes)
      raise_access_check_error do
        DeserializationError::Permissions.new(
          "Attempt to make illegal changes to viewmodel '#{self.class.view_name}'",
          self.blame_reference)
      end
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

  private

  def raise_access_check_error
    err = @access_check_error || yield
    @access_check_error = nil
    raise err
  end
end

require 'view_model/utils'
require 'view_model/error'
require 'view_model/deserialization_error'
require 'view_model/serialization_error'
require 'view_model/registry'
require 'view_model/references'
require 'view_model/reference'
require 'view_model/serialize_context'
require 'view_model/deserialize_context'
