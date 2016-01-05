require "active_support"
require "active_record"
require "cerego_active_record_patches"

class ActiveRecordViewModel < ViewModel
  # An AR ViewModel wraps a single AR model
  attribute :model

  class << self
    attr_accessor :_table, :_model_attributes

    def table(table)
      t = table.to_s.camelize.safe_constantize
      if t.nil? || !(t < ActiveRecord::Base)
        raise ArgumentError.new("ActiveRecord model #{table} not found")
      end
      self._table = t
    end

    def inherited(subclass)
      subclass._attributes = self._attributes
      subclass._model_attributes = []
      subclass.attribute(:id)
    end

    def attribute(attr)
      _model_attributes << attr

      define_method(attr) do |**options|
        model.public_send(attr)
      end unless method_defined?(attr)

      define_method("#{attr}=") do |value, **options|
        model.public_send("#{attr}=", value)
      end unless method_defined?("#{attr}=")
    end

    def all_attributes
      attrs = _table.attribute_names - _table.reflect_on_all_associations(:belongs_to).map(&:foreign_key)
      attrs.each { |attr| attribute(attr) }
    end

    # `acts_as_list` maintains a `position_changed` instance variable, which
    # suppresses position recalculation if the setter was called, even if the
    # value wasn't altered. Because we rely on being able to reset attributes to
    # their current value without effect, handle this case specially by only
    # invoking the setter if the value is different.
    def acts_as_list(attr = :position)
      setter_defined = method_defined?("#{attr}=")

      attribute(attr)

      define_method("#{attr}=") do |value, **options|
        if value != model.public_send(attr)
          super(attr, **options)
        end
      end unless setter_defined
    end

    def association(target, viewmodel: nil)
      reflection = _table.reflect_on_association(target)

      if reflection.nil?
        raise ArgumentError.new("Association #{target} not found in #{_table.name} model")
      end

      if viewmodel.nil?
        viewmodel_name = reflection.klass.name + "View"
        viewmodel = viewmodel_name.safe_constantize

        if viewmodel.nil? || !(viewmodel < ViewModel)
          raise ArgumentError.new("Default ViewModel class '#{viewmodel_name}' for AR model '#{reflection.klass.name}' not found")
        end
      end

      _model_attributes << target

      define_method target do |**options|
        read_association(reflection, viewmodel)
      end unless method_defined?(target)

      define_method :"#{target}=" do |data, **options|
        write_association(reflection, viewmodel, data)
      end unless method_defined?(:"#{target}=")

      define_method :"build_#{target}" do |data, **options|
        build_association(reflection, viewmodel, data)
      end unless method_defined?(:"build_#{target}")
    end

    def associations(*assocs)
      assocs.each { |assoc| association(assoc) }
    end

    def create_or_update_from_view(hash_data, model_cache: nil, root_node: true)
      _table.transaction do
        if id = hash_data["id"]
          # Update an existing model. If this model isn't the root of the tree
          # being modified, we need to first save the model to have any changes
          # applied before calling `replace` on the parent's association.
          model = if model_cache.nil?
                    _table.find(id)
                  else
                    model_cache[id]
                  end
          self.new(model)._update_from_view(hash_data, save: true)
        else
          # Create a new model. If we're not the root of the tree we need to
          # refrain from saving, so that foreign keys to the parent can be
          # populated when the parent and association are saved.
          model = _table.new
          self.new(model)._update_from_view(hash_data, save: root_node)
        end
      end
    end
  end

  def initialize(model)
    unless model.is_a?(self.class._table)
      raise ArgumentError.new("'#{model.inspect}' is not an instance of #{self.class._table.name}")
    end
    super(model)
  end

  def serialize_view(json, **options)
    self.class._model_attributes.each do |attr_name|
      json.set! attr_name do
        self.class.serialize(self.public_send(attr_name), json, **options)
      end
    end
  end

  def create_or_update_associated(association_name, hash_data)
    self.class._table.transaction do
      self.public_send(:"build_#{association_name}", hash_data)
      model.save!
    end
  end


  def destroy!
    model.destroy!
  end


  # Iterate the hash and update the model. Internal implementation, private to
  # class and metaclass.
  def _update_from_view(hash_data, save: true)
    hash_data.each do |k, v|
      next if k == "id"
      self.public_send("#{k}=", v)
    end

    model.save! if save

    self
  end

  private

  def read_association(reflection, viewmodel)
    associated = model.public_send(reflection.name)

    if associated.nil?
      nil
    elsif reflection.collection?
      associated.map { |x| viewmodel.new(x) }
    else
      viewmodel.new(associated)
    end
  end

  # Create or update an entire associated subtree, replacing the current
  # contents if necessary.
  def write_association(reflection, viewmodel, data)
    association = model.association(reflection.name)

    if reflection.collection?
      # preload any existing models: if they're referred to, we require them to exist.
      ids = data.map { |h| h["id"] }.compact
      models_by_id = ids.blank? ? {} : reflection.klass.find_all!(ids).index_by(&:id)

      assoc_views = data.map do |hash|
        viewmodel.create_or_update_from_view(hash, model_cache: models_by_id, root_node: false)
      end

      assoc_models = assoc_views.map(&:model)
      association.replace(assoc_models)
    else
      if data.nil?
        new_record = false
        assoc_model = nil
      else
        new_record = model["id"].nil?
        assoc_view = viewmodel.create_or_update_from_view(data, root_node: false)
        assoc_model = assoc_view.model
      end

      if reflection.macro == :belongs_to
        garbage_collect_belongs_to_association(reflection, assoc_model, new_record)
      end

      association.replace(assoc_model)
    end
  end

  # Create or update a single member of an associated subtree. For a collection
  # association, this appends to the collection, otherwise it has the same
  # effect as `write_association`.
  def build_association(reflection, viewmodel, data)
    if reflection.collection?
      association = model.association(reflection.name)
      assoc_view  = viewmodel.create_or_update_from_view(data, root_node: false)
      assoc_model = assoc_view.model
      association.concat(assoc_model)
    else
      write_association(reflection, viewmodel, data)
    end
  end


  def garbage_collect_belongs_to_association(reflection, target, new_record)
    return unless [:delete, :destroy].include?(reflection.options[:dependent])

    existing_fkey = model.public_send(reflection.foreign_key)
    if existing_fkey != target.try(&:id)
      association = model.association(reflection.name)

      # we need to manually garbage collect the old associated record if present
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


  # TODO: How about visibility/customization? We could consider visibility
  # filters along the lines of `jsonapi-resources`. Customization comes
  # reasonably easily with overriding.

  # What do we want the API to look like?
  # I think it's desirable to have the `build_association` accessible via
  # POST /model/1/associatedmodel, to create an associatedmodel linked to model 1


end
