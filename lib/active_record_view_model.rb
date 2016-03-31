require "active_support"
require "active_record"

require "view_model"

require "cerego_active_record_patches"
require "iknow_list_utils"
require "lazily"

class ActiveRecordViewModel < ViewModel
  using IknowListUtils

  METADATA = ["_type"]

  AssociationData = Struct.new(:reflection, :viewmodel_spec) do
    delegate :polymorphic?, :collection?, :klass, :name, to: :reflection

    def pointer_location # TODO name
      case reflection.macro
      when :belongs_to
        :local
      when :has_one, :has_many
        :remote
      end
    end
  end

  class DeserializeContext

    def initialize
      @root_updates = Array.new
      @post_execute_hooks = Array.new
      @releases = Hash.new
      @takes = Hash.new
    end

    def add_node_update(update)
      @root_updates << update

      update.each_child do |u|
        u.releases.each do |m|
          @releases[m] = u
        end

        u.takes.each do |m|
          # TODO check for duplicate takes?
          @takes[m] = u
        end
      end

    end

    def detect_moves
      @takes.each do |taken_model, take_update|
        puts "#{taken_model.class.name}(#{taken_model.id}) is taken by #{take_update}"
        if (release = @releases[taken_model])
          release.move_to!(taken_model, take_update)
        else
          puts "Update plan:"
          @root_updates.each(&:print)

          # This can't be a warning, otherwise the old association won't be cleared out
          # the release is both the permission to release an object, and clearing the old association
          raise "Missing release for taken object #{taken_model.class.name}(id=#{taken_model.id})"
        end
      end
    end

    def execute!
      detect_moves
      puts "Update plan:"
      @root_updates.each(&:print)
      @root_updates.each { |u| u.run!(self) }
      @post_execute_hooks.each(&:call)
    end

    def register_post_execute_hook(&hook)
      @post_execute_hooks << hook
    end
  end

  class NodeUpdate
    attr_reader :model

    def initialize(model)
      @model = model
      @attributes = Hash.new
      @points_to = Hash.new
      @pointed_to = Hash.new
      @inverse = Hash.new
    end

    def add_attribute_update(name, value)
      @attributes[name] = value
    end

    def add_points_to_association_update(name, update)
      @points_to[name] = update
    end

    def add_pointed_to_association_update(name, update)
      @pointed_to[name] = update
    end

    def add_inverse_update(name, update)
      @inverse[name] = update
    end

    def releases
      []
    end

    def takes
      []
    end

    def each_child
      yield(self)
      @points_to.each { |_, u| u.each_child { |u| yield(u) } }
      @pointed_to.each { |_, u| u.each_child { |u| yield(u) } }
    end

    def print(prefix = nil)
      puts "#{prefix}#{self.class.name} #{model.class.name}(id=#{model.id || 'new'})"
      prefix = "#{prefix}  "
      @attributes.each do |attr, value|
        puts "#{prefix}#{attr}=#{value}"
      end
      @points_to.each do |name, value|
        puts "#{prefix}#{name} = "
        value.print("#{prefix}  ")
      end
      @inverse.each do |name, value|
        puts "#{prefix}#{name} = <inverse>"
      end
      puts "#{prefix}save!"
      @pointed_to.each do |name, value|
        puts "#{prefix}#{name} = "
        value.print("#{prefix}  ")
      end
    end

    def run!(context)
      @attributes.each do |attr, value|
        model.public_send(:"#{attr}=", value)
      end

      @points_to.each do |name, update|
        model.association(name).replace(update.run!(context))
      end

      @inverse.each do |name, update|
        model.association(name).replace(update.model)
      end

      model.save!

      # now we have dropped the references to @points_to old models, we can do their deletes

      @pointed_to.each do |name, update|
        model.association(name).target = update.run!(context)
      end

      model
    end
  end

  class AssociationChange
    attr_reader :move, :from_model, :to_update, :association_data

    def move_to!(model, update)
      @move = true
    end

    def initialize(association_data, from_model, to_update)
      @association_data = association_data
      @from_model = from_model
      @to_update = to_update
    end

    def print(prefix = nil)
      puts "#{prefix}#{self.class.name}"
      prefix = "#{prefix}  "
      if from_model
        puts "#{prefix} from: #{from_model.class.name}(id=#{from_model.id})"
        puts "#{prefix}   move=#{@move.present?}"
      end
      if to_update
        puts "#{prefix} to:"
        to_update.print("#{prefix}  ")
      end
    end

    def each_child
      yield self
      @to_update.each_child { |u| yield(u) } if @to_update
    end

    def releases
      if @from_model
        [@from_model]
      else
        []
      end
    end

    def takes
      if @to_update && !@to_update.model.new_record?
        [@to_update.model]
      else
        []
      end
    end

    def run!(context)
      destroy_option = association_data.reflection.options[:dependent]
      if from_model && !@move && [:delete, :destroy].include?(destroy_option)
        case destroy_option
        when :delete
          context.register_post_execute_hook { from_model.delete }
        when :destroy
          context.register_post_execute_hook { from_model.destroy }
        end
      end
      to_update.run!(context) if to_update
    end
  end

  class AssociationCollectionChange
    attr_reader :to_update, :releases, :takes

    def initialize(releases, takes, to_update)
      @releases = releases
      @takes = takes
      @to_update = to_update
      @move = Hash.new
    end

    def move_to!(model, update)
      @move[model] = update
    end

    def each_child
      yield self
      @to_update.each { |u| u.each_child { |c| yield(c) } }
    end

    def print(prefix = nil)
      puts "#{prefix}#{self.class.name}"
      prefix = "#{prefix}  "
      if releases.present?
        puts "#{prefix}releases: ["
        @releases.each do |m|
          puts "#{prefix} #{m.class.name}(id=#{m.id})"
          puts "#{prefix}   move? #{@move[m]}"
        end
        puts "#{prefix}]"
      end

      if takes.present?
        puts "#{prefix}takes: ["
        takes.each do |m|
          puts "#{prefix} #{m.class.name}(id=#{m.id})"
        end
        puts "#{prefix}]"
      end

      if to_update.present?
        puts "#{prefix}to: ["
        to_update.map { |u| u.print("#{prefix}  ") }
        puts "#{prefix}]"
      end
    end

    def run!(context)
      @releases.each do |released_model|
        released_model.delete unless @move[released_model]
      end
      to_update.map { |u| u.run!(context) }
    end
  end

  # An AR ViewModel wraps a single AR model
  attribute :model

  class << self
    attr_reader :_members, :_associations, :_list_attribute_name

    delegate :transaction, to: :model_class

    def inherited(subclass)
      # copy ViewModel setup
      subclass._attributes = self._attributes

      subclass.initialize_members
    end

    def initialize_members
      @_members = []
      @_associations = {}

      @generated_accessor_module = Module.new
      include @generated_accessor_module

      attribute(:id)
    end

    # Specifies an attribute from the model to be serialized in this view
    def attribute(attr)
      _members << attr

      @generated_accessor_module.module_eval do
        define_method attr do
          model.public_send(attr)
        end

        define_method "serialize_#{attr}" do |json, **options|
          value = self.public_send(attr)
          self.class.serialize(value, json, **options)
        end

        define_method "deserialize_#{attr}" do |value, **options|
          deserialize_member(attr, value, **options)
        end
      end
    end

    # Specifies that an attribute refers to an `acts_as_enum` constant.  This
    # provides special serialization behaviour to ensure that the constant's
    # string value is serialized rather than the model object.
    def acts_as_enum(*attrs)
      attrs.each do |attr|
        @generated_accessor_module.module_eval do
          redefine_method("serialize_#{attr}") do |json, **options|
            value = self.public_send(attr)
            self.class.serialize(value.enum_constant, json, **options)
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

    def _reorder_list_members(data)
      # If the position attribute is explicitly exposed in the viewmodel, then
      # allow positions to be specified by the user by pre-sorting using any
      # specified position values as a partial order, followed in original
      # array order by models without position specified.
      if _members.include?(_list_attribute_name)
        data = data.map(&:dup)

        n = 0
        data.sort_by! do |h|
          pos = h.delete(_list_attribute_name.to_s)
          # TODO try to unify? not handle as two different sequences
          if pos.nil?
            [1, n += 1]
          else
            [0, pos]
          end
        end
      end

      data
    end

    # Specifies an association from the model to be recursively serialized using
    # another viewmodel. If the target viewmodel is not specified, attempt to
    # locate a default viewmodel based on the name of the associated model.
    def association(association_name, viewmodel: nil, viewmodels: nil)
      reflection = model_class.reflect_on_association(association_name)

      if reflection.nil?
        raise ArgumentError.new("Association #{association_name} not found in #{model_class.name} model")
      end

      unless reflection.validate?
        # If the record is not validated then we will ignore save failures
        # and partially store user data.
        raise ArgumentError.new("Association #{association_name} does not have validation enabled")
      end

      unless reflection.polymorphic?
        inverse = reflection.inverse_of
        if inverse.present? && inverse.validate?
          raise ArgumentError.new("Association #{self} #{association_name}'s inverse (#{inverse}) has validation enabled, creating a cycle'")
        end
      end

      viewmodel_spec = viewmodel || viewmodels

      _members << association_name
      _associations[association_name] = AssociationData.new(reflection, viewmodel_spec)

      @generated_accessor_module.module_eval do
        define_method association_name do
          read_association(association_name)
        end

        define_method :"serialize_#{association_name}" do |json, **options|
          associated = self.public_send(association_name)
          self.class.serialize(associated, json, **options)
        end

        define_method :"deserialize_#{association_name}" do |hash_data, **options|
          deserialize_association(association_name, hash_data, **options)
        end

        define_method :"append_#{association_name}" do |data, **options|
          append_association(association_name, data, **options)
        end

        define_method :"delete_#{association_name}" do |associated, **options|
          delete_association(association_name, associated, **options)
        end
      end
    end


    # Specify multiple associations at once
    def associations(*assocs)
      assocs.each { |assoc| association(assoc) }
    end

    ## Load an instance of the viewmodel by id
    def find(id, scope: nil, eager_include: true, **options)
      find_scope = model_scope(eager_include: eager_include, **options)
      find_scope = find_scope.merge(scope) if scope
      self.new(find_scope.find(id))
    end

    ## Load instances of the viewmodel by scope
    ## TODO: is this too much of a encapsulation violation?
    def load(scope: nil, eager_include: true, **options)
      load_scope = model_scope(eager_include: eager_include, **options)
      load_scope = load_scope.merge(scope) if scope
      load_scope.map { |model| self.new(model) }
    end

    def deserialize_one(hash_data, context:, **options)
      if _is_update_hash?(hash_data)
        id = _update_id(hash_data)
        model = model_scope.find(id)
        viewmodel = self.new(model)
        update = viewmodel._update_from_view(hash_data, context: context, **options)
        context.add_node_update(update)
      else
        model = model_class.new
        viewmodel = self.new(model)
        update = viewmodel._update_from_view(hash_data, context: context, **options)
        context.add_node_update(update)
      end

      viewmodel
    end

    def deserialize_from_view(hash_data, **options)
      context = DeserializeContext.new

      model_class.transaction do
        extra = hash_data.delete("_aux")
        result = self.deserialize_one(hash_data, context: context, **options)
        if extra
          extra.each do |extra_data|
            self.deserialize_one(extra_data, context: context, **options)
          end
        end
        context.execute!

        result
      end
    end


    # TODO: Need to sort out preloading for polymorphic viewmodels: how do you
    # specify "when type A, go on to load these, but type B go on to load
    # those?"
    def eager_includes(**options)
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
          viewmodel = _viewmodel_for(association_data.klass, association_data.viewmodel_spec)
          children = viewmodel.eager_includes(**options)
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
        match = /(.*)View$/.match(self.name)
        raise ArgumentError.new("Could not auto-determine AR model name from ViewModel name '#{self.name}'") if match.nil?
        self.model_class_name = match[1]
      end

      @model_class
    end

    def model_scope(eager_include: true, **options)
      scope = self.model_class.all
      if eager_include
        scope = scope.includes(self.eager_includes(**options))
      end
      scope
    end

    # internal
    def _association_data(association_name)
      association_data = self._associations[association_name]
      raise ArgumentError.new("Invalid association") if association_data.nil?
      association_data
    end

    # internal
    def _is_update_hash?(hash_data)
      hash_data.has_key?("id")
    end

    # internal
    def _update_id(hash_data)
      hash_data["id"]
    end

    # internal
    def _viewmodel_for(klass, override_spec)
      case override_spec
      when ActiveRecordViewModel
        viewmodel = override_spec
      when Hash
        viewmodel = override_spec[klass.name]
        if viewmodel.nil? || !(viewmodel < ActiveRecordViewModel)
          raise ArgumentError.new("ViewModel for associated class '#{klass.name}' not specified in manual association")
        end
      when nil
        viewmodel_name = (klass.name + "View")
        viewmodel = viewmodel_name.safe_constantize
        if viewmodel.nil? || !(viewmodel < ActiveRecordViewModel)
          raise ArgumentError.new("Default ViewModel class '#{viewmodel_name}' for associated class '#{klass.name}' not found")
        end
      else
        raise ArgumentError.new("Invalid viewmodel specification: '#{override_spec}'")
      end

      viewmodel
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

  def initialize(model = nil)
    model ||= model_class.new

    unless model.is_a?(model_class)
      raise ArgumentError.new("'#{model.inspect}' is not an instance of #{model_class.name}")
    end

    super(model)
  end

  def serialize_view(json, **options)
    json.set!("_type", self.model_class.name)
    self.class._members.each do |member_name|
      json.set! member_name do
        self.public_send("serialize_#{member_name}", json, **options)
      end
    end
  end

  def destroy!(**options)
    model_class.transaction do
      editable!(**options)
      model.destroy!
    end
  end

  class UnimplementedException < Exception
  end

  def unimplemented
    raise UnimplementedException.new
  end

  def deserialize_associated(association_name, hash_data, **options)
    unimplemented

    view = nil
    model_class.transaction do
      editable!(**options)
      case hash_data
      when Hash
        view = self.public_send(:"append_#{association_name}", hash_data, **options)
      else
        raise ViewModel::DeserializationError.new("Invalid data for association: '#{hash_data.inspect}'")
      end
      model.save!
    end
    view
  end

  def delete_associated(association_name, associated, **options)
    unimplemented

    model_class.transaction do
      editable!(**options)
      self.public_send(:"delete_#{association_name}", associated, **options)
      # Ensure the model is saved and hooks are run in case the implementor
      # overrides `delete_x`
      model.save!
    end
  end

  def load_associated(association_name)
    self.public_send(association_name)
  end

  def find_associated(association_name, id, eager_include: true, **options)
    associated_viewmodel = viewmodel_for_association(association_name)
    association_scope = self.model.association(association_name).association_scope
    associated_viewmodel.find(id, scope: association_scope, eager_include: eager_include, **options)
  end

  # Update the model based on attributes in the hash.
  # Internal implementation, private to class and metaclass.
  def _update_from_view(hash_data, context:, **options)
    editable!(**options)
    valid_members = self.class._members.map(&:to_s)

    # check for bad data
    bad_keys = hash_data.keys.reject { |k| valid_members.include?(k) || METADATA.include?(k) }

    if bad_keys.present?
      raise ViewModel::DeserializationError.new("Illegal member(s) #{bad_keys.inspect} when updating #{self.class.name}")
    end

    update = NodeUpdate.new(self.model)

    valid_members.each do |member|
      next if member == "id" || member == "_type"

      if hash_data.has_key?(member)
        val = hash_data[member]
        self.public_send("deserialize_#{member}", val, update: update, context: context, **options)
      end
    end

    update
  end

  # For a given assocaition, set the value, with full rails style updates
  def _set_association(association_name, viewmodel_value)
    # TODO how does this work?
    model.association(association_name).replace(viewmodel_value.model)
  end

  private

  def read_association(association_name)
    associated = model.public_send(association_name)
    return nil if associated.nil?

    association_data = self.class._association_data(association_name)
    associated_viewmodel = viewmodel_for_association(association_name)
    if association_data.collection?
      associated = associated.map { |x| associated_viewmodel.new(x) }
      if associated_viewmodel._list_member?
        associated.sort_by!(&:_list_attribute)
      end
      associated
    else
      associated_viewmodel.new(associated)
    end
  end

  def deserialize_member(name, value, update:, context:, **options)
    update.add_attribute_update(name, value)
  end

  def deserialize_association_collection(association_data, hash_data, update:, context:, **options)
    inverse_reflection = association_data.reflection.inverse_of

    viewmodel = viewmodel_for_association(association_data.name)

    # preload any existing models: if they're referred to, we require them to
    # exist.
    unless hash_data.is_a?(Array)
      raise ViewModel::DeserializationError.new(
        "Invalid hash data array for multiple association: '#{hash_data.inspect}'")
    end

    # infer user order from position attributes and passed array
    hash_data = viewmodel._reorder_list_members(hash_data) if viewmodel._list_member?

    # load children already attached to this model
    existing_children = model.public_send(association_data.name).index_by(&:id)

    # load children not attached to this parent so they're available when
    # building the viewmodels.

    # TODO: double loading here, maybe
    other_children_ids = hash_data
                           .lazy
                           .map { |x| x["id"] }
                           .reject { |x| x.nil? || existing_children.include?(x) }
                           .to_a

    other_children = viewmodel.model_class
                       .find_all!(other_children_ids)
                       .index_by(&:id)

    vm_children = hash_data.map do |x|
      id = x["id"]
      viewmodel.new(existing_children[id] || other_children[id])
    end

    discarded_children = existing_children.values - vm_children.map(&:model)
    taken_children = (vm_children.map(&:model) - existing_children.values).reject(&:new_record?)

    if inverse_reflection.nil?
      raise "Reflection has no inverse, cannot insert into list #{self.class}##{association_data.name}"
    end

    updates = Array.new
    vm_children.zip(hash_data) do |child, data|
      new_update = child._update_from_view(data, context: context, **options)
      unless existing_children.values.include?(child.model)
        new_update.add_inverse_update(inverse_reflection.name, update)
      end
      updates << new_update
    end

    if viewmodel._list_member?
      list_attr = viewmodel._list_attribute_name

      viewmodel.model_class.interleaved_positions(
        updates,
        in_list: ->(x) { existing_children.values.include?(x.model) },
        position: ->(x) { x.model.public_send(list_attr) }
      ) do |u, new_position|
        u.add_attribute_update(list_attr, new_position)
      end
    end

    update.add_pointed_to_association_update(
      association_data.name,
      AssociationCollectionChange.new(discarded_children, taken_children, updates))

    nil
  end

  def _add_association_update(parent_update, association_data, new_update)
    if association_data.pointer_location == :local
      parent_update.add_points_to_association_update(association_data.name, new_update)
    else

      parent_update.add_pointed_to_association_update(association_data.name, new_update)
    end
  end

  def deserialize_association_single(association_data, hash_data, update:, context:, **options)
    assoc_model = self.model.public_send(association_data.name)

    if hash_data.nil?
      # Remove the attachment to the label, only if the pointer will not be cleaned up as part of the release action.
      if assoc_model
        _add_association_update(update, association_data, AssociationChange.new(association_data, assoc_model, nil))
      end
    elsif hash_data.is_a?(Hash)
      # This is an ugly hack to see if we can do polymorphism right
      klass = if association_data.reflection.polymorphic?
                if (type = hash_data["_type"])
                  type.constantize # TODO gaping security vulnerability?
                else
                  raise DeserializationError.new("Missing type in polymorphic record")
                end
              else
                association_data.reflection.klass
              end

      viewmodel = self.class._viewmodel_for(klass, association_data.viewmodel_spec)
      is_new_record = !viewmodel._is_update_hash?(hash_data)

      if is_new_record
        assoc_view = viewmodel.new
        assoc_update = assoc_view._update_from_view(hash_data, context: context, **options)
        if association_data.pointer_location == :remote
          assoc_update.add_inverse_update(association_data.reflection.inverse_of.name, update)
        end

        _add_association_update(update, association_data, AssociationChange.new(association_data, assoc_model, assoc_update))
      else
        if assoc_model.id == viewmodel._update_id(hash_data) && assoc_model.class == viewmodel.model_class
          # current child is targetted, update in place
          # ... what if type changes?
          assoc_view = viewmodel.new(assoc_model)
          assoc_update = assoc_view._update_from_view(hash_data, context: context, **options)
          _add_association_update(update, association_data, assoc_update)

        else
          # reparenting something else
          existing_model = viewmodel.model_class.find(viewmodel._update_id(hash_data))
          assoc_view = viewmodel.new(existing_model)
          assoc_update = assoc_view._update_from_view(hash_data, context: context, **options)
          if association_data.pointer_location == :remote
            assoc_update.add_inverse_update(association_data.reflection.inverse_of.name, update)
          end
          _add_association_update(update, association_data, AssociationChange.new(association_data, assoc_model, assoc_update))
        end

      end
    else
      raise ViewModel::DeserializationError.new("Invalid hash data for single association: '#{hash_data.inspect}'")
    end

    nil # no return value (TODO is this the ruby idiom?)
  end

  # Create or update an entire associated subtree from a serialized hash,
  # replacing the current contents if necessary.
  def deserialize_association(association_name, hash_data, update:, context:, **options)
    association_data = self.class._association_data(association_name)
    if association_data.collection?
      deserialize_association_collection(
        association_data, hash_data, update: update, context: context, **options)
    else
      deserialize_association_single(
        association_data, hash_data, update: update, context: context, **options)
    end
  end

  # Create or update a single member of an associated subtree. For a collection
  # association, this deserializes and appends to the collection, otherwise it
  # has the same effect as `deserialize_association`.
  def append_association(association_name, hash_data, **options)
    unimplemented

    association_data = self.class._association_data(association_name)

    if association_data.collection?
      association = model.association(association_name)
      viewmodel = viewmodel_for_association(association_name)
      assoc_view = viewmodel.deserialize_from_view(hash_data, **options)
      assoc_model = assoc_view.model
      association.concat(assoc_model)

      assoc_view
    else
      deserialize_association(association_name, hash_data, **options)
    end
  end

  # Removes the association between the models represented by this viewmodel and
  # the provided associated viewmodel. The associated model will be
  # garbage-collected if the assocation is specified with `dependent: :destroy`
  # or `:delete_all`
  def delete_association(association_name, associated, **options)
    unimplemented

    association_data = self.class._association_data(association_name)

    if association_data.collection?
      association = model.association(association_name)
      association.delete(associated.model)
    else
      # Delete using `deserialize_association` of nil to ensure that belongs_to
      # garbage collection is performed.
      deserialize_association(assocation_name, nil, **options)
    end
  end

  def viewmodel_for_association(association_name)
    association_data = self.class._association_data(association_name)

    association = model.association(association_name)
    klass = association.klass

    if klass.nil?
      raise ViewModel::DeserializationError.new("Couldn't identify target class for association `#{association.reflection.name}`: polymorphic type missing?")
    end

    self.class._viewmodel_for(klass, association_data.viewmodel_spec)
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

  ## Replace acts_as_list
  # - acts_as_list performs unnecessary O(n) aggregate queries across the list
  #   context on each update, and requires a really nasty patch to neuter the
  #   list context scope on new element insertions when rewriting the list
  #   (`deserialize__list_position`). If we know that updates will always go via
  #   ViewModels, we could do better by reimplementing list handling
  #   explicitly. An option would be to require that the model includes our own
  #   lightweight *explicitly used* acts_as_list replacement, which the
  #   viewmodel can use alongside as well as other service code?

  ## Belongs-to garbage collection
  # - Check that post save hooks for garbage collection can't clobber changes:
  #   consider what would happen if a A record had two references to B, and we
  #   change from {b1: x, b2: null} to {b1: null, b2: x} - the post-save hook
  #   for removing the record from b1 would destroy it, even though it now
  #   belongs to b2.

  ### Controllers

  # - Consider better support for queries or pagination

  # - Consider ways to represent `has_many:through:`, if we want to allow
  #   skipping a view for the join. If so, how do we manage manipulation of the
  #   association itself, do we allow attributes (such as ordering?) on the join
  #   table?
end
