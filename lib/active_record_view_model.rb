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

      define_method(attr) do
        model.public_send(attr)
      end unless method_defined?(attr)

      define_method("#{attr}=") do |value|
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

      define_method("#{attr}=") do |value|
        if value != model.public_send(attr)
          super(attr)
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

      define_method target do
        read_association(reflection, viewmodel)
      end unless method_defined?(target)

      define_method :"#{target}=" do |data|
        write_association(reflection, viewmodel, data)
      end unless method_defined?(:"#{target}=")

      define_method :"build_#{target}" do |data|
        build_association(reflection, viewmodel, data)
      end unless method_defined?(:"#{target}=")
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
          # Create a new model. If we're not the root of the tree, we need to
          # refrain from saving, so that foreign keys to a newly created parent
          # can be populated together when the parent node is saved.
          model = _table.new
          self.new(model)._update_from_view(hash_data, save: root_node)
        end
      end
    end
  end


  def serialize_view(json, **options)
    self.class._model_attributes.each do |attr_name|
      json.set! attr_name do
        self.class.serialize(self.public_send(attr_name), json, **options)
      end
    end
  end

  # Should only be called from `create_or_update_from_view`
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

  # Create or update an entire associated subtree, replacing current contents if necessary.
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
        assoc_model = nil
      else
        assoc_view = viewmodel.create_or_update_from_view(data, root_node: false)
        assoc_model = assoc_view.model
      end

      if reflection.macro == :belongs_to && [:dependent, :destroy].include?(reflection.options[:dependent])

        existing_fkey = model.public_send(reflection.foreign_key)
        if existing_fkey != assoc_model.try(&:id)
          # we need to manually garbage collect the old associated record if present
          if existing_fkey.present?
            case reflection.options[:dependent]
            when :destroy
              association.association_scope.destroy_all
            when :delete
              association.association_scope.delete_all
            end
          end

          # and ensure that the new target, if it already existed and was not already
          # the current target, doesn't belong to another association
          if assoc_model.present? && data["id"].present?
            raise "Todo"
          end
        end
      end

      association.replace(assoc_model)
    end
  end

  # Create or update a single member of an associated subtree (for a collection association, adds)
  # TODO: what if the reverse association is multiple? throw?
  # TODO: will acts_as_list behave itself?
  # what happens when you build a single association that's already populated? does it clean up the old one?
  def build_association(reflection, viewmodel, data)
    association = model.association(reflection.name)
    if id = data["id"]
      existing_model = reflection.klass.find(id)
      # retarget the association to me, if it already isn't.
      raise "nope"
      viewmodel.new(existing_model).update_from_view(data, save: true)
    else
      new_model = association.build
      viewmodel.new(new_model).update_from_view(data, save: true)
    end
  end

  # How about visibility?

  # How about client views? We're not actually anxious about security of the
  # answers here (are we?) so do we even care to constrain the output? Or let
  # the front end handle it entirely?

  # we can have create and update separate if we like with POST vs PATCH

  # How can we create from context?
  # I think it's desirable to POST /model/1/associatedmodel to create an associatedmodel linked to model 1


  # but hey now we have the difference between create and update - how to handle?
  # => privilege the `id` attr, if it's provided, it's an update?

  # Cases
  # new or existing record, at a top level
  # => want to save when it's done, and update children at that point
  # new record, with a parent
  # => being created with `build`, and parent might be new: want to save (and our children) when parent is saved
  # existing record, with a parent
  # => parent might be new. If we belong_to the parent, we need to be updated when the parent is saved.
  # if parent belongs_to us, it can be updated right away.
  # But when would we actually be saved?

  # orphaned records need to be saved up to be destroyed, because if we
  # belong_to them we'll get a FK violation when destroying if we're not
  # done.

  # ===
  # alternative: universally use `new` and `replace` instead of `build`.
  # Can we use `replace` on something new?
  # => yes: it's not performed until it's saved
  # if our new thing `has_many` and we're going to `replace` with something existing that we want to change, can we save it?
  # => only if we can save it in advance
  # if our new thing `belongs_to`
  # => then the `replace` will maintain the foreign key

  # so this pretty much works because it's a post-order traversal, and any
  # links up the tree get maintained/updated when we hit the parent.

  # Well, almost. if it's a new record that's not the top level, when does
  # it get saved? We can't safely save at the end of the node because the
  # link to the parent isn't established. However because it's new, we know
  # it'll be saved when it's `replace`d into the parent.

  # Caveats:

  # 1: if we change an child item and then move its `belongs_to` to
  #    something new it gets hit in the db twice.
  # 2: acts_as_list doesn't hook `replace` at all, and because replace is
  #    eager we'd have to update the list positions. However, if the client
  #    is well-behaved, the update should be a no-op.
end
