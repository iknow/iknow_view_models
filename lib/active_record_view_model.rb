require "active_support"
require "active_record"
require "cerego_active_record_patches"

class ActiveRecordViewModel < ViewModel
  AssociationData = Struct.new(:reflection, :viewmodel_spec) do
    delegate :polymorphic?, :collection?, :klass, :name, to: :reflection
  end

  # An AR ViewModel wraps a single AR model
  attribute :model

  class << self
    attr_reader :_members, :_associations, :_list_attribute

    delegate :transaction, to: :model_class

    def model_class
      unless instance_variable_defined?(:@model_class)
        # try to auto-detect the model class based on our name
        match = /(.*)View$/.match(self.name)
        raise ArgumentError.new("Could not auto-determine AR model name from ViewModel name '#{self.name}'") if match.nil?
        self.model_class_name = match[1]
      end

      @model_class
    end

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

    def attribute(attr)
      _members << attr

      @generated_accessor_module.module_eval do
        define_method attr do |**options|
          model.public_send(attr)
        end

        define_method "#{attr}=" do |value, **options|
          model.public_send("#{attr}=", value)
        end
      end
    end

    def all_attributes
      attrs = model_class.attribute_names - model_class.reflect_on_all_associations(:belongs_to).map(&:foreign_key)
      attrs.each { |attr| attribute(attr) }
    end

    # `acts_as_enum`s can be assigned as strings, but return the AR model. We
    # want to serialize the string.
    def acts_as_enum(*attrs)
      attrs.each do |attr|
        @generated_accessor_module.module_eval do
          redefine_method(attr) do |**options|
            model.public_send(attr).enum_constant
          end
        end
      end
    end

    def acts_as_list(attr = :position)
      @_list_attribute = attr

      if _members.include?(attr)
        @generated_accessor_module.module_eval do
          # Additionally, if the list position attribute is exposed in the
          # viewmodel then we want to wrap the generated setter to maintain
          # correct acts_as_list behaviour.
          #
          # This is needed because `acts_as_list` maintains a `position_changed`
          # instance variable, which suppresses automatic position recalculation
          # if the setter was called, even if the value wasn't altered. Because
          # viewmodel deserialization relies on being able to reset attributes to
          # their current value without effect, handle this case specially by only
          # invoking the setter on the model if the value is different.
          redefine_method("#{attr}=") do |value, **options|
            if value != model.public_send(attr)
              model.public_send("#{attr}=", value)
            end
          end
        end
      end
    end

    def _list_member?
      _list_attribute.present?
    end

    def association(association_name, viewmodel: nil, viewmodels: nil)
      reflection = reflection_for(association_name)

      viewmodel_spec = viewmodel || viewmodels

      _members << association_name
      _associations[association_name] = AssociationData.new(reflection, viewmodel_spec)

      @generated_accessor_module.module_eval do
        define_method association_name do |**options|
          read_association(association_name)
        end

        define_method  :"#{association_name}=" do |data, **options|
          write_association(association_name, data)
        end

        define_method :"build_#{association_name}" do |data, **options|
          build_association(association_name, data)
        end

        define_method :"delete_#{association_name}" do |associated, **options|
          delete_association(association_name, associated)
        end
      end
    end

    def associations(*assocs)
      assocs.each { |assoc| association(assoc) }
    end

    def association_data(association_name)
      association_data = self._associations[association_name]
      raise ArgumentError.new("Invalid association") if association_data.nil?
      association_data
    end

    ## Load an instance of the viewmodel by id
    def find(id, scope: nil, eager_include: true, **options)
      scope = model_scope(eager_include: eager_include, **options).merge(scope)
      self.new(scope.find(id))
    end

    ## Load instances of the viewmodel by scope
    ## TODO: is this too much of a encapsulation violation?
    def load(scope: nil, eager_include: true, **options)
      scope = model_scope(eager_include: eager_include, **options).merge(scope)
      scope.map { |model| self.new(model) }
    end

    def deserialize_from_view(hash_data, model_cache: nil, root_node: true, **options)
      model_class.transaction do
        if is_update_hash?(hash_data)
          # Update an existing model. If this model isn't the root of the tree
          # being modified, we need to first save the model to have any changes
          # applied before calling `replace` on the parent's association.
          id = update_id(hash_data)
          model = if model_cache.nil?
                    model_scope.find(id)
                  else
                    model_cache[id]
                  end
          self.new(model)._update_from_view(hash_data, save: true, **options)
        else
          # Create a new model. If we're not the root of the tree we need to
          # refrain from saving, so that foreign keys to the parent can be
          # populated when the parent and association are saved.
          model = model_class.new
          self.new(model)._update_from_view(hash_data, save: root_node, **options)
        end
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
          viewmodel = viewmodel_for(association_data.klass, association_data.viewmodel_spec)
          children = viewmodel.eager_includes(**options)
        end

        h[assoc_name] = children
      end
    end

    def model_scope(eager_include: true, **options)
      scope = self.model_class.all
      if eager_include
        scope = scope.includes(self.eager_includes(**options))
      end
      scope
    end

    # internal
    def is_update_hash?(hash_data)
      hash_data.has_key?("id")
    end

    # internal
    def update_id(hash_data)
      hash_data["id"]
    end

    # internal
    def viewmodel_for(klass, override_spec)
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

    def model_class_name=(name)
      type = name.to_s.camelize.safe_constantize
      raise ArgumentError.new("Could not find model class '#{name}'") if type.nil?
      self.model_class = type
    end

    def model_class=(type)
      if instance_variable_defined?(:@model_class)
        raise ArgumentError.new("Model class for ViewModel '#{self.name}' already set")
      end

      unless type < ActiveRecord::Base
        raise ArgumentError.new("'#{type.inspect}' is not a valid ActiveRecord model class")
      end
      @model_class = type
    end

    def reflection_for(association_name)
      reflection = model_class.reflect_on_association(association_name)

      if reflection.nil?
        raise ArgumentError.new("Association #{association_name} not found in #{model_class.name} model")
      end

      reflection
    end
  end

  delegate :model_class, to: :class

  def initialize(model)
    unless model.is_a?(model_class)
      raise ArgumentError.new("'#{model.inspect}' is not an instance of #{model_class.name}")
    end

    super(model)

    @post_save_hooks = []
  end

  def serialize_view(json, **options)
    self.class._members.each do |member_name|
      json.set! member_name do
        self.class.serialize(self.public_send(member_name), json, **options)
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
      when Array
        view = self.public_send(:"#{association_name}=", hash_data, **options)
      when Hash
        view = self.public_send(:"build_#{association_name}", hash_data, **options)
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

  def load_associated(association_name, **options)
    self.public_send(association_name, **options)
  end

  def find_associated(association_name, id, eager_include: true, **options)
    associated_viewmodel = viewmodel_for_association(association_name)
    association_scope = self.model.association(association_name).association_scope
    associated_viewmodel.find(id, scope: association_scope, eager_include: eager_include, **options)
  end

  # Update the model based on attributes in the hash.
  # Internal implementation, private to class and metaclass.
  def _update_from_view(hash_data, save: true, **options)
    editable!(**options)
    valid_members = self.class._members.map(&:to_s) + ["_list_position"]

    # check for bad data
    bad_keys = hash_data.keys.reject {|k| valid_members.include?(k) }

    if bad_keys.present?
      raise ViewModel::DeserializationError.new("Illegal member(s) #{bad_keys.inspect} when updating #{self.class.name}")
    end

    valid_members.each do |member|
      next if member == "id"

      if hash_data.has_key?(member)
        val = hash_data[member]
        self.public_send("#{member}=", val, **options)
      end
    end

    if save
      model.save!
      self.run_post_save_hooks
    end

    self
  end

  # internal
  def _list_position
    raise ViewModel::DeserializationError.new("ViewModel does not represent a list member") unless self.class._list_member?
    model.public_send(self.class._list_attribute)
  end

  # internal
  def _list_position=(value, **options)
    raise ViewModel::DeserializationError.new("ViewModel does not represent a list member") unless self.class._list_member?
    # This setter is used when reassigning all positions in the list: because
    # the whole list is being rewritten, we want to disable acts_as_list's
    # ability to alter the order after each position change.

    # We only need to do this if it's a new record (and what's more, if we do it
    # to an existing record it will prevent a moved child from being removed
    # from its old parent)
    model.define_singleton_method(:scope_condition){ "1 = 0" } if model.new_record?
    model.public_send("#{self.class._list_attribute}=", value)
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

    association_data = self.class.association_data(association_name)
    viewmodel = viewmodel_for_association(association_name)
    if association_data.collection?
      associated = associated.map { |x| viewmodel.new(x) }
      associated.sort_by!(&:_list_position) if viewmodel._list_member?
      associated
    else
      viewmodel.new(associated)
    end
  end

  # Create or update an entire associated subtree, replacing the current
  # contents if necessary.
  def write_association(association_name, hash_data)
    association_data = self.class.association_data(association_name)

    association = model.association(association_name)

    if association_data.collection?
      viewmodel = viewmodel_for_association(association_name)

      # preload any existing models: if they're referred to, we require them to
      # exist.
      unless hash_data.is_a?(Array)
        raise ViewModel::DeserializationError.new("Invalid hash data array for multiple association: '#{hash_data.inspect}'")
      end

      model_cache = model.public_send(association_name).index_by(&:id)
      missing_model_ids = hash_data.map { |h| viewmodel.update_id(h) }.reject { |id| id.nil? || model_cache.has_key?(id) }

      if missing_model_ids.present?
        viewmodel.model_scope.find_all!(missing_model_ids).each { |model| model_cache[model.id] = model }
      end

      # if we're writing an ordered list, put the members in the target order.
      if viewmodel._list_member?
        hash_data = reorder_list_members(viewmodel, hash_data)
      end

      assoc_views = hash_data.map do |hash|
        viewmodel.deserialize_from_view(hash, model_cache: model_cache, root_node: false)
      end

      assoc_models = assoc_views.map(&:model)
      association.replace(assoc_models)

      assoc_views.each do |v|
        if v.pending_post_save_hooks?
          register_post_save_hook { v.run_post_save_hooks }
        end
      end

      assoc_views
    else
      # single association
      previous_assoc_model = model.public_send(association_name)

      if hash_data.nil?
        is_new_record = false
        assoc_model = nil
      elsif hash_data.is_a?(Hash)
        viewmodel = viewmodel_for_association(association_name)
        is_new_record = !viewmodel.is_update_hash?(hash_data)
        model_cache = nil

        # Might have already eager loaded the model if the target isn't being changed
        if !is_new_record && previous_assoc_model.id == viewmodel.update_id(hash_data)
          model_cache = { previous_assoc_model.id => previous_assoc_model }
        end

        assoc_view = viewmodel.deserialize_from_view(hash_data, root_node: false, model_cache: model_cache)

        if assoc_view.pending_post_save_hooks?
          register_post_save_hook { assoc_view.run_post_save_hooks }
        end

        assoc_model = assoc_view.model
      else
        raise ViewModel::DeserializationError.new("Invalid hash data for single association: '#{hash_data.inspect}'")
      end

      if association_data.reflection.macro == :belongs_to
        garbage_collect_belongs_to_association(association_data.reflection, previous_assoc_model, assoc_model, is_new_record)
      end

      association.replace(assoc_model)
      assoc_view
    end
  end

  # Create or update a single member of an associated subtree. For a collection
  # association, this appends to the collection, otherwise it has the same
  # effect as `write_association`.
  def build_association(association_name, hash_data)
    association_data = self.class.association_data(association_name)

    if association_data.collection?
      association = model.association(association_name)
      viewmodel   = viewmodel_for_association(association_name)
      assoc_view  = viewmodel.deserialize_from_view(hash_data, root_node: false)
      assoc_model = assoc_view.model
      association.concat(assoc_model)

      if assoc_view.pending_post_save_hooks?
        register_post_save_hook { assoc_view.run_post_save_hooks }
      end
      assoc_view
    else
      write_association(association_name, hash_data)
    end
  end

  # Removes the association between the models represented by this viewmodel and
  # the provided associated viewmodel. The associated model will be
  # garbage-collected if the assocation is specified with `dependent: :destroy`
  # or `:delete_all`
  def delete_association(association_name, associated)
    association_data = self.class.association_data(association_name)

    if association_data.collection?
      association = model.association(association_name)
      association.delete(associated.model)
    else
      write_association(assocation_name, nil)
    end
  end

  def register_post_save_hook(&block)
    @post_save_hooks << block
  end

  def viewmodel_for_association(association_name)
    association_data = self.class.association_data(association_name)

    association = model.association(association_name)
    klass = association.klass

    if klass.nil?
      raise ViewModel::DeserializationError.new("Couldn't identify target class for association `#{association.reflection.name}`: polymorphic type missing?")
    end

    self.class.viewmodel_for(klass, association_data.viewmodel_spec)
  end

  def reorder_list_members(viewmodel, hashes)
    # If the position attribute is explicitly exposed in the viewmodel, then
    # allow positions to be specified by the user by pre-sorting using any
    # specified position values as a partial order, followed in original
    # array order by models without position specified.
    if viewmodel._members.include?(viewmodel._list_attribute)
      hashes = hashes.map(&:dup)

      n = 0
      hashes.sort_by! do |h|
        pos = h.delete(viewmodel._list_attribute.to_s)
        if pos.nil?
          [1, n += 1]
        else
          [0, pos]
        end
      end
    end

    hashes.each_with_index do |h, i|
      # Use our internal setter that neuters the acts_as_list hook scope
      h["_list_position"] = i + 1
    end

    hashes
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

      # TODO: we might not want to support this. It's expensive, requires an
      # index, and, doesn't play well with nullness or fkey constraints. This
      # ties into a bigger question: how do we support moving a child from one
      # parent to another, with each of the different association types?
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

  ## Create tools for customizing visibility and access control
  # Besides manually rewriting setters/getters.  We could could consider
  # visibility filters along the lines of `jsonapi-resources`.

  ## Do we want to support defining any kind of constraints on associations?

  ## Eager loading
  # - Come up with a way to represent (and perform!) type-conditional eager
  #  loads for polymorphic associations

  ## Support for single table inheritance (if necessary)

  ## Ensure that we have correct behaviour when a polymorphic relationship is changed to an entity of a different type
  # - does the old one get correctly garbage collected?

  ## Throw an error if the same entity is specified twice

  ## Replace acts_as_list
  # - It's not ok that we rewrite the positions every time, even if nothing is changed
  # - acts_as_list performs O(n) aggregate queries across the list context
  # - acts_as_list's activerecord hooks don't update other affected model objects, so
  #   the models built in a newly deserialized viewmodel may not reflect reality
  # -  our post-save hook *definitely* doesn't update the model objects
  # - if we take it out, what's our solution for services that manipulate the
  #   models directly?  we don't want to leave them to rewrite position
  #   manipulation. Should we require that the model includes our own
  #   lightweight *explicitly used* acts_as_list replacement, which the
  #   viewmodel can use as well as other code?

  ## Belongs-to garbage collection
  # - may or may not be desirable
  # - doesn't have a post-save hook
  # - Check that post save hooks for garbage collection can't clobber changes:
  #   consider what would happen if a A record had two references to B, and we
  #   change from {b1: x, b2: null} to {b1: null, b2: x} - the post-save hook
  #   for removing the record from b1 would destroy it, even though it now
  #   belongs to b2.

  ### Controllers

  ## Consider better support for queries or pagination

  ## Generate controllers for writing to associations

  ## if we remove acts_as_list, how will DELETE actions ensure that the list is maintained?
  # - could have a `#destroy` method to the viewmodel which maintains the list, and always use that?
end
