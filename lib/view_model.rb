# frozen_string_literal: true

# A ViewModel encapsulates a particular aggregation of data calculated via the
# underlying models and provides a means of serializing it into views.
require 'jbuilder'
require 'deep_preloader'

class ViewModel
  REFERENCE_ATTRIBUTE = '_ref'
  ID_ATTRIBUTE        = 'id'
  TYPE_ATTRIBUTE      = '_type'
  VERSION_ATTRIBUTE   = '_version'
  NEW_ATTRIBUTE       = '_new'

  # Migrations leave a metadata attribute _migrated on any views that they
  # alter. This attribute is accessible as metadata when deserializing migrated
  # input, and is included in the output serialization sent to clients.
  MIGRATED_ATTRIBUTE  = '_migrated'

  Metadata = Struct.new(:id, :view_name, :schema_version, :new, :migrated) do
    alias_method :new?, :new
  end

  class << self
    attr_accessor :_attributes
    attr_accessor :schema_version
    attr_reader   :view_aliases
    attr_writer   :view_name

    def inherited(subclass)
      super
      subclass.initialize_as_viewmodel
    end

    def initialize_as_viewmodel
      @_attributes    = []
      @schema_version = 1
      @view_aliases   = []
    end

    def view_name
      @view_name ||=
        begin
          # try to auto-detect based on class name
          match = /(.*)View$/.match(self.name)
          raise ArgumentError.new("Could not auto-determine ViewModel name from class name '#{self.name}'") if match.nil?

          ViewModel::Registry.default_view_name(match[1])
        end
    end

    def add_view_alias(as)
      view_aliases << as
      ViewModel::Registry.register(self, as: as)
    end

    # ViewModels are either roots or children. Root viewmodels may be
    # (de)serialized directly, whereas child viewmodels are always nested within
    # their parent. Associations to root viewmodel types always use indirect
    # references.
    def root?
      false
    end

    def root!
      define_singleton_method(:root?) { true }
    end

    # ViewModels are typically going to be pretty simple structures. Make it a
    # bit easier to define them: attributes specified this way are given
    # accessors and assigned in order by the default constructor.
    def attributes(*attrs, **args)
      attrs.each { |attr| attribute(attr, **args) }
    end

    def attribute(attr, **_args)
      unless attr.is_a?(Symbol)
        raise ArgumentError.new('ViewModel attributes must be symbols')
      end

      attr_accessor attr

      define_method("deserialize_#{attr}") do |value, references: {}, deserialize_context: self.class.new_deserialize_context|
        self.public_send("#{attr}=", value)
      end
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

    def member_names
      _attributes.map(&:to_s)
    end

    # In deserialization, verify and extract metadata from a provided hash.
    def extract_viewmodel_metadata(hash)
      ViewModel::Schemas.verify_schema!(ViewModel::Schemas::VIEWMODEL_UPDATE, hash)
      id             = hash.delete(ViewModel::ID_ATTRIBUTE)
      type_name      = hash.delete(ViewModel::TYPE_ATTRIBUTE)
      schema_version = hash.delete(ViewModel::VERSION_ATTRIBUTE)
      new            = hash.delete(ViewModel::NEW_ATTRIBUTE) { false }
      migrated       = hash.delete(ViewModel::MIGRATED_ATTRIBUTE) { false }

      Metadata.new(id, type_name, schema_version, new, migrated)
    end

    def extract_reference_only_metadata(hash)
      ViewModel::Schemas.verify_schema!(ViewModel::Schemas::VIEWMODEL_UPDATE, hash)
      id             = hash.delete(ViewModel::ID_ATTRIBUTE)
      type_name      = hash.delete(ViewModel::TYPE_ATTRIBUTE)

      Metadata.new(id, type_name, nil, false, false)
    end

    def extract_reference_metadata(hash)
      ViewModel::Schemas.verify_schema!(ViewModel::Schemas::VIEWMODEL_REFERENCE, hash)
      hash.delete(ViewModel::REFERENCE_ATTRIBUTE)
    end

    def is_update_hash?(hash) # rubocop:disable Naming/PredicateName
      ViewModel::Schemas.verify_schema!(ViewModel::Schemas::VIEWMODEL_UPDATE, hash)
      hash.has_key?(ViewModel::ID_ATTRIBUTE) &&
        !hash.fetch(ViewModel::ActiveRecord::NEW_ATTRIBUTE, false)
    end

    # If this viewmodel represents an AR model, what associations does it make
    # use of? Returns a includes spec appropriate for DeepPreloader, either as
    # AR-style nested hashes or DeepPreloader::Spec.
    def eager_includes(serialize_context: new_serialize_context, include_referenced: true)
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
        json.merge!({})
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

    def serialize_from_cache(views, migration_versions: {}, locked: false, serialize_context:)
      plural = views.is_a?(Array)
      views = Array.wrap(views)

      json_views, json_refs = ViewModel::ActiveRecord::Cache.render_viewmodels_from_cache(
                    views, locked: locked, migration_versions: migration_versions, serialize_context: serialize_context)

      json_views = json_views.first unless plural
      return json_views, json_refs
    end

    def encode_json(value)
      # Jbuilder#encode no longer uses MultiJson, but instead calls `.to_json`. In
      # the context of ActiveSupport, we don't want this, because AS replaces the
      # .to_json interface with its own .as_json, which demands that everything is
      # reduced to a Hash before it can be JSON encoded. Using this is not only
      # slightly more expensive in terms of allocations, but also defeats the
      # purpose of our precompiled `CompiledJson` terminals. Instead serialize
      # using OJ with options equivalent to those used by MultiJson.
      Oj.dump(value, mode: :compat, time_format: :ruby, use_to_json: true)
    end

    # Rebuild this viewmodel from a serialized hash.
    def deserialize_from_view(hash_data, references: {}, deserialize_context: new_deserialize_context)
      viewmodel = self.new
      deserialize_members_from_view(viewmodel, hash_data, references: references, deserialize_context: deserialize_context)
      viewmodel
    end

    def deserialize_members_from_view(viewmodel, view_hash, references:, deserialize_context:)
      ViewModel::Callbacks.wrap_deserialize(viewmodel, deserialize_context: deserialize_context) do |hook_control|
        if (bad_attrs = view_hash.keys - member_names).present?
          causes = bad_attrs.map do |bad_attr|
            ViewModel::DeserializationError::UnknownAttribute.new(bad_attr, viewmodel.blame_reference)
          end
          raise ViewModel::DeserializationError::Collection.for_errors(causes)
        end

        member_names.each do |attr|
          next unless view_hash.has_key?(attr)

          viewmodel.public_send("deserialize_#{attr}",
                                view_hash[attr],
                                references: references,
                                deserialize_context: deserialize_context)
        end

        deserialize_context.run_callback(ViewModel::Callbacks::Hook::BeforeValidate, viewmodel)
        viewmodel.validate!

        # More complex viewmodels can use this hook to track changes to
        # persistent backing models, and record the results. Primitive
        # viewmodels record no changes.
        if block_given?
          yield(hook_control)
        else
          hook_control.record_changes(Changes.new)
        end
      end
    end

    def serialize_context_class
      ViewModel::SerializeContext
    end

    def new_serialize_context(...)
      serialize_context_class.new(...)
    end

    def deserialize_context_class
      ViewModel::DeserializeContext
    end

    def new_deserialize_context(...)
      deserialize_context_class.new(...)
    end

    def accepts_schema_version?(schema_version)
      schema_version == self.schema_version
    end

    def schema_versions(viewmodels)
      viewmodels.each_with_object({}) do |view, h|
        h[view.view_name] = view.schema_version
      end
    end

    def schema_hash(schema_versions)
      version_string = schema_versions.to_a.sort.join(',')
      # We want a short hash value, as this will be used in cache keys
      hash = Digest::SHA256.digest(version_string).byteslice(0, 16)
      Base64.urlsafe_encode64(hash, padding: false)
    end

    def preload_for_serialization(viewmodels, serialize_context: new_serialize_context, include_referenced: true, lock: nil)
      Array.wrap(viewmodels).group_by(&:class).each do |type, views|
        DeepPreloader.preload(views.map(&:model),
                              type.eager_includes(serialize_context: serialize_context, include_referenced: include_referenced),
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
    ViewModel::Callbacks.wrap_serialize(self, context: serialize_context) do
      serialize_view(json, serialize_context: serialize_context)
    end
  end

  def to_hash(serialize_context: self.class.new_serialize_context)
    Jbuilder.new { |json| serialize(json, serialize_context: serialize_context) }.attributes!
  end

  def to_json(serialize_context: self.class.new_serialize_context)
    ViewModel.encode_json(self.to_hash(serialize_context: serialize_context))
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

  # Provide a stable way to identify this view through attribute changes. By
  # default views cannot make assumptions about the identity of our attributes,
  # so we fall back on the view's `object_id`. If a viewmodel is backed by a
  # model with a concept of identity, this method should be overridden to use
  # it.
  def id
    object_id
  end

  # Is this viewmodel backed by a model with a stable identity? Used to decide
  # whether the id is included when constructing a ViewModel::Reference from
  # this view.
  def stable_id?
    false
  end

  def validate!; end

  def to_reference
    ViewModel::Reference.new(self.class, (id if stable_id?))
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

  def context_for_child(member_name, context:)
    context.for_child(self, association_name: member_name)
  end

  def preload_for_serialization(lock: nil, serialize_context: self.class.new_serialize_context)
    ViewModel.preload_for_serialization([self], lock: lock, serialize_context: serialize_context)
  end

  def ==(other)
    other.class == self.class && self.class._attributes.all? do |attr|
      other.send(attr) == self.send(attr)
    end
  end

  alias eql? ==

  def hash
    features = self.class._attributes.map { |attr| self.send(attr) }
    features << self.class
    features.hash
  end
end

require 'view_model/config'
require 'view_model/utils'
require 'view_model/error'
require 'view_model/callbacks'
require 'view_model/access_control'
require 'view_model/deserialization_error'
require 'view_model/serialization_error'
require 'view_model/registry'
require 'view_model/references'
require 'view_model/reference'
require 'view_model/serialize_context'
require 'view_model/deserialize_context'
require 'view_model/changes'
require 'view_model/schemas'
require 'view_model/error_view'
require 'view_model/garbage_collection'
