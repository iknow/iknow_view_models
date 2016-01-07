require "active_support"
require "active_record"
require "cerego_active_record_patches"

class ActiveRecordViewModel < ViewModel
  # An AR ViewModel wraps a single AR model
  attribute :model

  class DeserializationError < StandardError
  end

  class << self
    attr_reader :_members, :_associations, :_list_attribute

    def table(table_name = nil)
      if table_name
        raise ArgumentError.new("Table for ViewModel '#{self.name}' already set") if @table.present?

        t = table_name.to_s.camelize.safe_constantize
        if t.nil? || !(t < ActiveRecord::Base)
          raise ArgumentError.new("ActiveRecord model #{table_name} not found")
        end
        @table = t
      end

      @table
    end

    def inherited(subclass)
      # copy ViewModel setup
      subclass._attributes = self._attributes

      subclass.initialize_members
    end

    def initialize_members
      @_members = []
      @_associations = []

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
      attrs = table.attribute_names - table.reflect_on_all_associations(:belongs_to).map(&:foreign_key)
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

    def association(target, viewmodel: nil, viewmodels: nil)
      reflection = reflection_for(target)

      viewmodel_spec = viewmodel || viewmodels

      _members << target
      _associations << target

      @generated_accessor_module.module_eval do
        define_method target do |**options|
          read_association(reflection, viewmodel_spec)
        end

        define_method  :"#{target}=" do |data, **options|
          write_association(reflection, viewmodel_spec, data)
        end

        define_method :"build_#{target}" do |data, **options|
          build_association(reflection, viewmodel_spec, data)
        end
      end
    end

    def associations(*assocs)
      assocs.each { |assoc| association(assoc) }
    end

    def deserialize_from_view(hash_data, model_cache: nil, root_node: true)
      table.transaction do
        if is_update_hash?(hash_data)
          # Update an existing model. If this model isn't the root of the tree
          # being modified, we need to first save the model to have any changes
          # applied before calling `replace` on the parent's association.
          id = hash_data["id"]
          model = if model_cache.nil?
                    table.includes(self.eager_includes).find(id)
                  else
                    model_cache[id]
                  end
          self.new(model)._update_from_view(hash_data, save: true)
        else
          # Create a new model. If we're not the root of the tree we need to
          # refrain from saving, so that foreign keys to the parent can be
          # populated when the parent and association are saved.
          model = table.new
          self.new(model)._update_from_view(hash_data, save: root_node)
        end
      end
    end

    def is_update_hash?(hash_data)
      hash_data.has_key?("id")
    end

    # TODO: This should be recursive. To be recursive, need to have saved the
    # `viewmodel_specs` for each association. For now, only loading one level.
    # Still going to have issues with polymorphic viewmodels: how do you specify
    # "when type A, go on to load these, but type B go on to load those?"
    def eager_includes(**options)
      _associations.each_with_object({}) do |assoc_name, h|
        reflection = reflection_for(assoc_name)
        h[reflection.name] = nil
      end
    end

    private

    def reflection_for(association_name)
      reflection = table.reflect_on_association(association_name)

      if reflection.nil?
        raise ArgumentError.new("Association #{association_name} not found in #{table.name} model")
      end

      reflection
    end

  end

  def initialize(model)
    unless model.is_a?(self.class.table)
      raise ArgumentError.new("'#{model.inspect}' is not an instance of #{self.class.table.name}")
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

  def deserialize_associated(association_name, hash_data)
    self.class.table.transaction do
      self.public_send(:"build_#{association_name}", hash_data)
      model.save!
      self.run_post_save_hooks
    end
  end


  def destroy!
    model.destroy!
  end


  # Update the model based on attributes in the hash. Internal implementation, private to
  # class and metaclass.
  def _update_from_view(hash_data, save: true)
    valid_members = self.class._members.map(&:to_s)

    # check for bad data
    bad_keys = hash_data.keys.reject {|k| valid_members.include?(k) }

    if bad_keys.present?
      raise DeserializationError.new("Illegal member(s) #{bad_keys.inspect} when updating #{self.class.name}")
    end

    valid_members.each do |member|
      next if member == "id"

      if hash_data.has_key?(member)
        val = hash_data[member]
        self.public_send("#{member}=", val)
      end
    end

    if save
      model.save!
      self.run_post_save_hooks
    end

    self
  end

  def _list_position
    raise DeserializationError.new("ViewModel does not represent a list member") unless self.class._list_member?
    model.public_send(self.class._list_attribute)
  end

  def _list_position=(value)
    raise DeserializationError.new("ViewModel does not represent a list member") unless self.class._list_member?
    ###    model.define_singleton_method(:scope_condition){ "0" } if model.new_record?
    model.public_send("#{self.class._list_attribute}=", value)
  end

  private

  def read_association(reflection, viewmodel_spec)
    associated = model.public_send(reflection.name)
    return nil if associated.nil?

    association = model.association(reflection.name)
    viewmodel = viewmodel_for(association, viewmodel_spec)
    if reflection.collection?
      associated = associated.map { |x| viewmodel.new(x) }
      associated.sort_by!(&:_list_position) if viewmodel._list_member?
      associated
    else
      viewmodel.new(associated)
    end
  end

  # Create or update an entire associated subtree, replacing the current
  # contents if necessary.
  def write_association(reflection, viewmodel_spec, hash_data)
    association = model.association(reflection.name)

    if reflection.collection?
      viewmodel = viewmodel_for(association, viewmodel_spec)

      # preload any existing models: if they're referred to, we require them to
      # exist.
      # TODO: if we're editing an existing model, then we'll have already
      # preloaded the association with its eager includes. Only re-fetch
      # unloaded records here.
      unless hash_data.is_a?(Array)
        raise DeserializationError.new("Invalid hash data array for multiple association: '#{hash_data.inspect}'")
      end

      ids = hash_data.map { |h| h["id"] }.compact
      models_by_id = ids.blank? ? {} : association.klass.find_all!(ids).index_by(&:id)

      # if we're writing an ordered list, put the members in the target order.
      if viewmodel._list_member?
        hash_data = reorder_list_members(viewmodel, hash_data)
      end

      assoc_views = hash_data.map do |hash|
        viewmodel.deserialize_from_view(hash, model_cache: models_by_id, root_node: false)
      end

      assoc_models = assoc_views.map(&:model)
      association.replace(assoc_models)

      assoc_views.each do |v|
        if v.pending_post_save_hooks?
          register_post_save_hook { v.run_post_save_hooks }
        end
      end

      if assoc_views.present? && viewmodel._list_member?
        # after save of the parent, force the updated models into their target positions.

        # downside: this will get run every time, even if we're only adding new
        # records (positions will be correct) or editing non-position fields
        # (nothing changed). How can we identify if the positions in the models
        # need to change, with the understanding that in the event of moving a
        # member in from another list, acts_as_list could have clobbered other
        # previously existing members of this list?
        register_post_save_hook do
          update_cases = ""
          assoc_models.each_with_index do |model, i|
            update_cases << " WHEN #{model.id} THEN #{i + 1}"
          end

          viewmodel.table.where(id: assoc_models).update_all(<<-SQL)
            #{viewmodel._list_attribute} = CASE id #{update_cases} END
          SQL
        end
      end
    else
      # single association
      if hash_data.nil?
        new_record = false
        assoc_model = nil
      elsif hash_data.is_a?(Hash)
        viewmodel = viewmodel_for(association, viewmodel_spec)

        new_record = hash_data["id"].nil?
        # TODO: not taking advantage of the model possibly being preloaded
        assoc_view = viewmodel.deserialize_from_view(hash_data, root_node: false)
        assoc_model = assoc_view.model

        if assoc_view.pending_post_save_hooks?
          register_post_save_hook { assoc_view.run_post_save_hooks }
        end
      else
        raise DeserializationError.new("Invalid hash data for single association: '#{hash_data.inspect}'")
      end

      if reflection.macro == :belongs_to
        garbage_collect_belongs_to_association(reflection, assoc_model, new_record)
      end

      association.replace(assoc_model)
    end
  end

  def register_post_save_hook(&block)
    @post_save_hooks << block
  end

  protected def run_post_save_hooks
    @post_save_hooks.each { |hook| hook.call }
    @post_save_hooks = []
  end

  protected def pending_post_save_hooks?
    @post_save_hooks.present?
  end

  # Create or update a single member of an associated subtree. For a collection
  # association, this appends to the collection, otherwise it has the same
  # effect as `write_association`.
  def build_association(reflection, viewmodel_spec, hash_data)
    if reflection.collection?
      association = model.association(reflection.name)
      viewmodel   = viewmodel_for(association, viewmodel_spec)
      assoc_view  = viewmodel.deserialize_from_view(hash_data, root_node: false)
      assoc_model = assoc_view.model
      association.concat(assoc_model)

      if assoc_view.pending_post_save_hooks?
        register_post_save_hook { assoc_view.run_post_save_hooks }
      end
    else
      write_association(reflection, viewmodel_spec, hash_data)
    end
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

    hashes
  end

  def garbage_collect_belongs_to_association(reflection, target, new_record)
    return unless [:delete, :destroy].include?(reflection.options[:dependent])

    existing_fkey = model.public_send(reflection.foreign_key)
    if existing_fkey != target.try(&:id)
      association = model.association(reflection.name)

      # we need to manually garbage collect the old associated record if present
      # TODO: This violates foreign key constraints: we need to save up the
      # scopes to garbage collect and destroy them after saving the record
      if existing_fkey.present?
        case reflection.options[:dependent]
        when :destroy
          association.association_scope.destroy_all
        when :delete
          association.association_scope.delete_all
        end
      end

      # Additionally, ensure that the new target, if it already
      # existed and was not already the current target, doesn't belong to
      # another association.

      # TODO: we might not want to support this. It's expensive, requires an
      # index, and, doesn't play well with nullness or fkey constraints. This
      # ties into a bigger question: how do we support moving a child from one
      # parent to another, with each of the different association types?
      if target.present? && !new_record
        # We might not have an inverse specified: only update if present
        reflection.inverse_of.try do |inverse_reflection|
          inverse_association = target.association(inverse_reflection.name)
          inverse_association.association_scope.update_all(inverse_reflection.foreign_key => nil)
        end
      end
    end
  end

  def viewmodel_for(association, override)
    klass = association.klass

    if klass.nil?
      raise DeserializationError.new("Couldn't identify target class for association `#{association.reflection.name}`: polymorphic type missing?")
    end

    case override
    when ActiveRecordViewModel
      viewmodel = override
    when Hash
      viewmodel = override[klass.name]
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
      raise ArgumentError("Invalid viewmodel specification: ")
    end

    viewmodel
  end


  ####### TODO LIST ########

  ## Create tools for customizing visibility and access control
  # Besides manually rewriting setters/getters.  We could could consider
  # visibility filters along the lines of `jsonapi-resources`.

  ## Do we want to support defining any kind of constraints on associations?

  ## Eager loading
  # - Correctly use eager loaded associations when present in `write_association`
  # - Fix eager loading so it's recursive
  # - Come up with a way to represent (and perform!) type conditional eager
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

  ## Fix check that update is operating on the desired target item

  ## Generate controllers for writing to associations

  ## if we remove acts_as_list, how will DELETE actions ensure that the list is maintained?
  # - could have a `#destroy` method to the viewmodel which maintains the list, and always use that?
end
