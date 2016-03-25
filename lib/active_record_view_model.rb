require "active_support"
require "active_record"

require "view_model"

require "cerego_active_record_patches"
require "iknow_list_utils"
require "lazily"

class ActiveRecordViewModel < ViewModel
  using IknowListUtils

  AssociationData = Struct.new(:reflection, :viewmodel_spec) do
    delegate :polymorphic?, :collection?, :klass, :name, to: :reflection
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

    def deserialize_from_view(hash_data, **options)
      release_pool = Set.new
      model_class.transaction do
        if _is_update_hash?(hash_data)
          # Update an existing model. If this model isn't the root of the tree
          # being modified, we need to first save the model to have any changes
          # applied before calling `replace` on the parent's association.
          id = _update_id(hash_data)
          model = model_scope.find(id)
          viewmodel = self.new(model)
          if hash_data.size > 1
            # includes data to recursively deserialize
            viewmodel._update_from_view(hash_data, release_pool: release_pool, **options)
          end
        else
          # Create a new model. If we're not the root of the tree we need to
          # refrain from saving, so that foreign keys to the parent can be
          # populated when the parent and association are saved.
          model = model_class.new
          viewmodel = self.new(model)
          viewmodel._update_from_view(hash_data, release_pool: release_pool, **options)
        end

        # TODO distinguish types/dependents
        release_pool.each do |x|
          # TODO actually do something useful, this just might let some
          # tests run.
          puts "Garbage after deserialize_from_view: #{x.class.name}(id=#{x.id})"
        end
        release_pool.each(&:destroy)

        viewmodel
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

    @post_save_hooks = []
  end

  def serialize_view(json, **options)
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

  def deserialize_associated(association_name, hash_data, **options)
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
      self.run_post_save_hooks
    end
    view
  end

  def delete_associated(association_name, associated, **options)
    model_class.transaction do
      editable!(**options)
      self.public_send(:"delete_#{association_name}", associated, **options)
      # Ensure the model is saved and hooks are run in case the implementor
      # overrides `delete_x`
      model.save!
      self.run_post_save_hooks
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
  def _update_from_view(hash_data, release_pool:, **options)
    editable!(**options)
    valid_members = self.class._members.map(&:to_s)

    # check for bad data
    bad_keys = hash_data.keys.reject { |k| valid_members.include?(k) }

    if bad_keys.present?
      raise ViewModel::DeserializationError.new("Illegal member(s) #{bad_keys.inspect} when updating #{self.class.name}")
    end

    deserialize_member = ->(member) do
      if hash_data.has_key?(member)
        val = hash_data[member]
        self.public_send("deserialize_#{member}", val, release_pool: release_pool, **options)
      end
    end

    attributes = []
    point_to_associations = []
    pointed_from_associations = []
    valid_members.each do |member|
      next if member == "id"

      if (association = self.class._associations[member.to_sym])
        case association.reflection.macro
        when :has_many, :has_one
          pointed_from_associations << member
        when :belongs_to
          point_to_associations << member
        else
          raise "Unknown reflection type"
        end
      else
        attributes << member
      end
    end

    attributes.each(&deserialize_member)
    point_to_associations.each(&deserialize_member)
    model.save!
    pointed_from_associations.each(&deserialize_member)

    self
  end

  # For a given assocaition, set the value, with full rails style updates
  def _set_association(association_name, viewmodel_value)
    # TODO how does this work?
    model.association(association_name).replace(viewmodel_value.model)
  end

  protected

  # internal
  def run_post_save_hooks
    @post_save_hooks.each { |hook| hook.call }
    @post_save_hooks = []
  end

  # internal
  def pending_post_save_hooks?
    @post_save_hooks.present?
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


  # raw set, for things that are entities set up the pointer without doing
  # the rails hooks and garbage collection.
  def set_associated_entity(association_name, viewmodel_value)
    association = model.association(association_name)
    reflection = association.try(&:reflection)
    case reflection.macro
    when :has_one, :has_many
      inverse_reflection = reflection.inverse_of
      viewmodel_value.model.association(inverse_reflection.name).replace(model)
    when :belongs_to
      association.replace(viewmodel_value.model)
    else
      raise "Cannot set unknown association type: #{reflection.macro}"
    end
  end

  # Create or update an entire associated subtree from a serialized hash,
  # replacing the current contents if necessary.
  def deserialize_association(association_name, hash_data, release_pool:, **options)
    association_data = self.class._association_data(association_name)

    if association_data.collection?
      viewmodel = viewmodel_for_association(association_name)

      # preload any existing models: if they're referred to, we require them to
      # exist.
      unless hash_data.is_a?(Array)
        raise ViewModel::DeserializationError.new("Invalid hash data array for multiple association: '#{hash_data.inspect}'")
      end

      # infer user order from position attributes and passed array
      hash_data = viewmodel._reorder_list_members(hash_data) if viewmodel._list_member?

      # load children already attached to this model
      existing_children = model.public_send(association_name).index_by(&:id)

      vm_children = hash_data.map do |x|
        viewmodel.new(existing_children[x["id"]])
      end

      discarded_children = existing_children.values - vm_children.map(&:model)
      release_pool.subtract(vm_children.map(&:model))
      release_pool.merge(discarded_children)

      if viewmodel._list_member?
        position_indices = vm_children
                             .lazy
                             .map(&:_list_attribute)
                             .with_index
                             .reject { |p, i| p.nil? }
                             .to_a

        # TODO we haven't dealt with collisions

        stable_positions = Lazily.concat([[nil, -1]],
                                         position_indices.longest_rising_sequence_by(&:first),
                                         [[nil, vm_children.length]])

        stable_positions.each_cons(2) do |(start_pos, start_index), (end_pos, end_index)|
          range = (start_index + 1)..(end_index - 1)
          next unless range.size > 0

          positions =
            case
            when start_pos.nil? && end_pos.nil?
              range
            when start_pos.nil? # before first fixed element
              range.size.downto(1).map { |i| end_pos - i }
            when end_pos.nil? # after
              1.upto(range.size).map { |i| start_pos + i }
            else
              delta = (end_pos - start_pos) / (range.size + 1)
              1.upto(range.size).map { |i| start_pos + delta * i }
            end

          positions.each.with_index(1) do |pos, i|
            vm_children[start_index + i]._list_attribute = pos
          end
        end
      end

      inverse_association_name = association_data.reflection.inverse_of.name

      vm_children.zip(hash_data) do |child, data|
        child._set_association(inverse_association_name, self)
        child._update_from_view(data, release_pool: release_pool, **options)
      end

      model.association(association_name).target = vm_children.map(&:model)

      vm_children
    else
      # single association
      assoc_model = self.model.public_send(association_name)

      if hash_data.nil?
        # no need to remove attachment, since either it's going into the pool
        # and being collected, or it's going to be reparented into something
        # else.
        release_pool.add(assoc_model) if assoc_model
        assoc_view = nil
      elsif hash_data.is_a?(Hash)
        viewmodel = viewmodel_for_association(association_name)
        is_new_record = !viewmodel._is_update_hash?(hash_data)

        if is_new_record
          release_pool.add(assoc_model) if assoc_model # remove old
          assoc_view = viewmodel.new
          set_associated_entity(association_name, assoc_view)
          assoc_view._update_from_view(hash_data, release_pool: release_pool, **options)
        else
          if assoc_model.id == viewmodel._update_id(hash_data)
            # current child is targetted, update in place
            assoc_view = viewmodel.new(assoc_model)
            assoc_view._update_from_view(hash_data, release_pool: release_pool, **options)
          else
            # reparenting something else
            release_pool.add(assoc_model) if assoc_model

            existing_model = viewmodel.model_class.find(viewmodel._update_id(hash_data))
            release_pool.delete(existing_model)

            assoc_view = viewmodel.new(existing_model)
            set_associated_entity(association_name, assoc_view)
            assoc_view._update_from_view(hash_data, release_pool: release_pool, **options)
          end
        end
      else
        raise ViewModel::DeserializationError.new("Invalid hash data for single association: '#{hash_data.inspect}'")
      end

      self.model.association(association_name).target = assoc_view.try(&:model)

      assoc_view
    end
  end

  # Create or update a single member of an associated subtree. For a collection
  # association, this deserializes and appends to the collection, otherwise it
  # has the same effect as `deserialize_association`.
  def append_association(association_name, hash_data, **options)
    association_data = self.class._association_data(association_name)

    if association_data.collection?
      association = model.association(association_name)
      viewmodel = viewmodel_for_association(association_name)
      assoc_view = viewmodel.deserialize_from_view(hash_data, **options)
      assoc_model = assoc_view.model
      association.concat(assoc_model)

      if assoc_view.pending_post_save_hooks?
        register_post_save_hook { assoc_view.run_post_save_hooks }
      end
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

  def register_post_save_hook(&block)
    @post_save_hooks << block
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


  def garbage_collect_belongs_to_association(reflection, old_target, new_target, is_new_record)
    return unless [:delete, :destroy].include?(reflection.options[:dependent])

    if old_target.try(&:id) != new_target.try(&:id)
      association = model.association(reflection.name)

      # we need to manually garbage collect the old associated record if present
      if old_target.present?
        garbage_scope = association.association_scope
        case reflection.options[:dependent]
        when :destroy
          register_post_save_hook { garbage_scope.destroy_all }
        when :delete
          register_post_save_hook { garbage_scope.delete_all }
        end
      end

      # Additionally, ensure that the new target, if it already
      # existed and was not already the current target, doesn't belong to
      # another association.
      if new_target.present? && !is_new_record
        # We might not have an inverse specified: only update if present
        reflection.inverse_of.try do |inverse_reflection|
          inverse_association = new_target.association(inverse_reflection.name)
          clearing_scope = inverse_association.association_scope.where("id != ?", model.id)
          register_post_save_hook { clearing_scope.update_all(inverse_reflection.foreign_key => nil) }
        end
      end
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
