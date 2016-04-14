require "active_support"
require "active_record"

require "view_model"

require "cerego_active_record_patches"
require "lazily"

module Views; end

class ActiveRecordViewModel < ViewModel
  require "active_record_view_model/update_operation"
  require "active_record_view_model/reference_operation"

  ID_ATTRIBUTE = "id"
  TYPE_ATTRIBUTE = "_type"
  REFERENCE_ATTRIBUTE = "_ref"

  AssociationData = Struct.new(:reflection, :viewmodel_classes, :shared) do
    delegate :polymorphic?, :collection?, :klass, :name, to: :reflection

    def initialize(reflection, viewmodel_classes, shared)
      if viewmodel_classes.nil?
        # If the association isn't polymorphic, we may be able to guess from the reflection
        model_class = reflection.klass
        if model_class.nil?
          raise ViewModel::DeserializationError.new("Couldn't derive target class for polymorphic association `#{reflection.name}`")
        end
        viewmodel_class = ActiveRecordViewModel.for_view_name(model_class.name) # TODO: improve error message to show it's looking for default name
        viewmodel_classes = [viewmodel_class]
      end

      super(reflection, Array.wrap(viewmodel_classes), shared)

      @model_to_viewmodel = viewmodel_classes.each_with_object({}) do |vm, h|
        h[vm.model_class] = vm
      end

      @name_to_viewmodel = viewmodel_classes.each_with_object({}) do |vm, h|
        h[vm.view_name] = vm
      end
    end

    def pointer_location # TODO name
      case reflection.macro
      when :belongs_to
        :local
      when :has_one, :has_many
        :remote
      end
    end

    def viewmodel_class_for_model(model_class)
      vm_class = @model_to_viewmodel[model_class]
      if vm_class.nil?
        raise ArgumentError.new("Can't find corresponding viewmodel to model '#{model_class.name}' for association '#{reflection.name}'")
      end
      vm_class
    end

    def viewmodel_class_for_name(name)
      vm_class = @name_to_viewmodel[name]
      if vm_class.nil?
        raise ArgumentError.new("Can't find corresponding viewmodel with name '#{name}' for association '#{reflection.name}'")
      end
      vm_class
    end

    def accepts?(viewmodel_class)
      viewmodel_classes.include?(viewmodel_class)
    end

    def viewmodel_class
      unless viewmodel_classes.size == 1
        raise ArgumentError.new("More than one possible class for association '#{reflection.name}'")
      end
      viewmodel_classes.first
    end
  end


  # An AR ViewModel wraps a single AR model
  attribute :model

  class << self
    attr_reader :_members, :_associations, :_list_attribute_name

    delegate :transaction, to: :model_class

    # The user-facing name of this viewmodel: serialized in the TYPE_ATTRIBUTE
    # field
    def view_name
      prefix = "#{Views.name}::"
      unless name.start_with?(prefix)
        raise "Illegal AR viewmodel: must be defined under module '#{prefix}'"
      end
      self.name[prefix.length..-1]
    end

    def for_view_name(name)
      raise ViewModel::DeserializationError.new("view name cannot be nil") if name.nil?

      class_name = "#{Views.name}::#{name}"
      viewmodel_class = class_name.safe_constantize
      if viewmodel_class.nil? || !(viewmodel_class < ActiveRecordViewModel)
        raise ArgumentError.new("ViewModel class '#{class_name}' not found")
      end
      viewmodel_class
    end

    def inherited(subclass)
      # copy ViewModel setup
      subclass._attributes = self._attributes

      subclass.initialize_members
    end

    def initialize_members
      @_members = {}
      @_associations = {}

      @generated_accessor_module = Module.new
      include @generated_accessor_module
    end

    # Specifies an attribute from the model to be serialized in this view
    def attribute(attr)
      _members[attr.to_s] = :attribute

      @generated_accessor_module.module_eval do
        define_method attr do
          model.public_send(attr)
        end

        define_method "serialize_#{attr}" do |json, view_context: default_serialize_context|
          value = self.public_send(attr)
          self.class.serialize(value, json, view_context: view_context)
        end

        define_method "deserialize_#{attr}" do |value, view_context: default_deserialize_context|
          model.public_send("#{attr}=", value)
        end
      end
    end

    # Specifies that an attribute refers to an `acts_as_enum` constant.  This
    # provides special serialization behaviour to ensure that the constant's
    # string value is serialized rather than the model object.
    def acts_as_enum(*attrs)
      attrs.each do |attr|
        @generated_accessor_module.module_eval do
          redefine_method("serialize_#{attr}") do |json, view_context: default_serialize_context|
            value = self.public_send(attr)
            self.class.serialize(value.enum_constant, json, view_context: view_context)
          end
        end
      end
    end

    # Specifies that the model backing this viewmodel is a member of an
    # `acts_as_list` collection.
    def acts_as_list(attr = :position)
      @_list_attribute_name = attr

      @generated_accessor_module.module_eval do
        define_method("_list_attribute") do
          model.public_send(attr)
        end

        define_method("_list_attribute=") do |x|
          model.public_send(:"#{attr}=", x)
        end
      end
    end

    def _list_member?
      _list_attribute_name.present?
    end

    # Specifies an association from the model to be recursively serialized using
    # another viewmodel. If the target viewmodel is not specified, attempt to
    # locate a default viewmodel based on the name of the associated model.
    def association(association_name, viewmodel: nil, viewmodels: nil, shared: false)
      reflection = model_class.reflect_on_association(association_name)

      if reflection.nil?
        raise ArgumentError.new("Association #{association_name} not found in #{model_class.name} model")
      end

      viewmodel_spec = viewmodel || viewmodels

      _members[association_name.to_s] = :association
      _associations[association_name.to_s] = AssociationData.new(reflection, viewmodel_spec, shared)

      @generated_accessor_module.module_eval do
        define_method association_name do
          read_association(association_name)
        end

        define_method :"serialize_#{association_name}" do |json, view_context: default_serialize_context|
          associated = self.public_send(association_name)

          if associated.nil?
            json.null!
          elsif shared
            reference = view_context.add_reference(associated)
            json.set!(ActiveRecordViewModel::REFERENCE_ATTRIBUTE, reference)
          else
            self.class.serialize(associated, json, view_context: view_context)
          end
        end
      end
    end

    # Specify multiple associations at once
    def associations(*assocs)
      assocs.each { |assoc| association(assoc) }
    end

    ## Load an instance of the viewmodel by id
    def find(id, scope: nil, eager_include: true, view_context: default_serialize_context)
      find_scope = model_scope(eager_include: eager_include, view_context: view_context)
      find_scope = find_scope.merge(scope) if scope
      self.new(find_scope.find(id))
    end

    ## Load instances of the viewmodel by scope
    ## TODO: is this too much of a encapsulation violation?
    def load(scope: nil, eager_include: true, view_context: default_serialize_context)
      load_scope = model_scope(eager_include: eager_include, view_context: view_context)
      load_scope = load_scope.merge(scope) if scope
      load_scope.map { |model| self.new(model) }
    end

    def deserialize_from_view(subtree_hashes, references: {}, view_context: default_deserialize_context)
      model_class.transaction do
        return_array = subtree_hashes.is_a?(Array)
        subtree_hashes = Array.wrap(subtree_hashes)

        root_updates, released_viewmodels = UpdateOperation.build_updates(subtree_hashes, references)

        updated_viewmodels = root_updates.map do |root_update|
          root_update.run!(view_context: view_context)
        end

        released_viewmodels.each_value do |release_entry|
          release_entry.release!
        end

        if return_array
          updated_viewmodels
        else
          updated_viewmodels.first
        end
      end
    end

    # TODO: Need to sort out preloading for polymorphic viewmodels: how do you
    # specify "when type A, go on to load these, but type B go on to load
    # those?"
    def eager_includes(view_context: default_serialize_context)
      _associations.each_with_object({}) do |(assoc_name, association_data), h|
        if association_data.polymorphic?
          # The regular AR preloader doesn't support child includes that are
          # conditional on type.  If we want to go through polymorphic includes,
          # we'd need to manually specify the viewmodel spec so that the
          # possible target classes are know, and also use our own preloader
          # instead of AR.
          children = nil
        else
          # if we have a known non-polymorphic association class, we can find
          # child viewmodels and recurse.
          viewmodel = association_data.viewmodel_class

          children = viewmodel.eager_includes(view_context: view_context)
        end

        h[assoc_name] = children
      end
    end

    # Returns the AR model class wrapped by this viewmodel. If this has not been
    # set via `model_class_name=`, attempt to automatically resolve based on the
    # name of this viewmodel.
    def model_class
      unless instance_variable_defined?(:@model_class)
        # try to auto-detect the model class based on our name
        self.model_class_name = self.view_name
      end

      @model_class
    end

    def model_scope(eager_include: true, view_context: default_serialize_context)
      scope = self.model_class.all
      if eager_include
        scope = scope.includes(self.eager_includes(view_context: view_context))
      end
      scope
    end

    # internal
    def _association_data(association_name)
      association_data = self._associations[association_name.to_s]
      raise ArgumentError.new("Invalid association") if association_data.nil?
      association_data
    end

    private

    # Set the AR model to be wrapped by this viewmodel
    def model_class_name=(name)
      type = name.to_s.camelize.safe_constantize
      raise ArgumentError.new("Could not find model class '#{name}'") if type.nil?
      self.model_class = type
    end

    # Set the AR model to be wrapped by this viewmodel
    def model_class=(type)
      if instance_variable_defined?(:@model_class)
        raise ArgumentError.new("Model class for ViewModel '#{self.name}' already set")
      end

      unless type < ActiveRecord::Base
        raise ArgumentError.new("'#{type.inspect}' is not a valid ActiveRecord model class")
      end
      @model_class = type
    end
  end

  delegate :model_class, to: :class
  delegate :id, to: :model

  def initialize(model = model_class.new)
    unless model.is_a?(model_class)
      raise ArgumentError.new("'#{model.inspect}' is not an instance of #{model_class.name}")
    end

    super(model)
  end

  def serialize_view(json, view_context: default_serialise_context)
    json.set!(ID_ATTRIBUTE, model.id)
    json.set!(TYPE_ATTRIBUTE, self.class.view_name)

    self.class._members.keys.each do |member_name|
      json.set! member_name do
        self.public_send("serialize_#{member_name}", json, view_context: view_context)
      end
    end
  end

  def destroy!(view_context: default_deserialize_context)
    model_class.transaction do
      editable!(view_context: view_context)
      model.destroy!
    end
  end

  class UnimplementedException < Exception; end
  def unimplemented
    raise UnimplementedException.new
  end

  # Entry point for appending to a collection association of an existing record
  # FIXME: no reason for this to be separate from append_association any more,
  # since we're no longer providing overridable append_* hooks for each association.
  def deserialize_associated(association_name, hash_data, view_context: default_deserialize_context)
    unimplemented

    view = nil
    model_class.transaction do
      editable!(view_context: view_context)
      case hash_data
      when Hash
        view = append_association(association_name, hash_data, view_context: view_context)
      else
        raise ViewModel::DeserializationError.new("Invalid data for association: '#{hash_data.inspect}'")
      end
      model.save!
    end
    view
  end

  # Entry point for destroying the association between an existing record and a child:
  # will be necessary for shared data.
  def delete_associated(association_name, associated, view_context: default_deserialize_context)
    unimplemented

    model_class.transaction do
      editable!(view_context: view_context)
      delete_association(association_name, associated, view_context: view_context)
    end
  end

  def load_associated(association_name)
    self.public_send(association_name)
  end

  def find_associated(association_name, id, eager_include: true, view_context: default_serialize_context)
    association_data = self.class._association_data(association_name)
    associated_viewmodel = association_data.viewmodel_class
    association_scope = self.model.association(association_name).association_scope
    associated_viewmodel.find(id, scope: association_scope, eager_include: eager_include, view_context: view_context)
  end

  private

  def read_association(association_name)
    associated = model.public_send(association_name)
    return nil if associated.nil?

    association_data = self.class._association_data(association_name)

    if association_data.collection?
      associated_viewmodel_class = association_data.viewmodel_class
      associated_viewmodels = associated.map { |x| associated_viewmodel_class.new(x) }
      if associated_viewmodel_class._list_member?
        associated_viewmodels.sort_by!(&:_list_attribute)
      end
      associated_viewmodels
    else
      associated_viewmodel_class = association_data.viewmodel_class_for_model(associated.class)
      associated_viewmodel_class.new(associated)
    end
  end

  # Create or update a single member of an associated subtree. For a collection
  # association, this deserializes and appends to the collection, otherwise it
  # has the same effect as `deserialize_association`.
  def append_association(association_name, hash_data, view_context: default_deserialize_context)
    unimplemented

    association_data = self.class._association_data(association_name)

    if association_data.collection?
      association = model.association(association_name)
      viewmodel = association_data.viewmodel_class
      assoc_view = viewmodel.deserialize_from_view(hash_data, view_context: view_context)
      assoc_model = assoc_view.model
      association.concat(assoc_model)

      assoc_view
    else
      deserialize_association(association_name, hash_data, view_context: view_context)
    end
  end

  # Removes the association between the models represented by this viewmodel and
  # the provided associated viewmodel. The associated model will be
  # garbage-collected if the assocation is specified with `dependent: :destroy`
  # or `:delete_all`
  def delete_association(association_name, associated, view_context: default_deserialize_context)
    unimplemented

    association_data = self.class._association_data(association_name)

    if association_data.collection?
      association = model.association(association_name)
      association.delete(associated.model)
    else
      # Delete using `deserialize_association` of nil to ensure that belongs_to
      # garbage collection is performed.
      deserialize_association(assocation_name, nil, view_context: view_context)
    end
  end


  ####### TODO LIST ########

  ## Eager loading
  # - Come up with a way to represent (and perform!) type-conditional eager
  #   loads for polymorphic associations

  ## Support for single table inheritance (if necessary)

  ## Ensure that we have correct behaviour when a polymorphic relationship is
  ## changed to an entity of a different type:
  # - does the old one get correctly garbage collected?

  ## Throw an error if the same entity is specified twice

  ### Controllers

  # - Consider better support for queries or pagination

  # - Consider ways to represent `has_many:through:`, if we want to allow
  #   skipping a view for the join. If so, how do we manage manipulation of the
  #   association itself, do we allow attributes (such as ordering?) on the join
  #   table?
end
