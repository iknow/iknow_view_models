require 'active_record_view_model/controller_base'

module ActiveRecordViewModel::Controller
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::ControllerBase

  included do
    delegate :viewmodel, to: :class
    @generated_routes_module = Module.new
    include @generated_routes_module
  end

  def initialize
    @view_options = {}
  end

  def show(scope: nil)
    viewmodel.transaction do
      view = viewmodel.find(params[:id], scope: scope, **@view_options)
      render_viewmodel({ data: view }, **@view_options)
    end
  end

  def index(scope: nil)
    viewmodel.transaction do
      views = viewmodel.load(scope: scope, **@view_options)
      render_viewmodel({ data: views }, **@view_options)
    end
  end

  def create
    deserialize(nil)
  end

  def update
    deserialize(params[:id])
  end

  def destroy(**view_options)
    viewmodel.transaction do
      view = viewmodel.find(params[:id], eager_load: false, **@view_options)
      view.destroy!(**@view_options)
    end
    render_viewmodel({ data: nil })
  end

  protected

  def set_view_option(key, value)
    @view_options[key] = value
  end

  private

  def deserialize(requested_id)
    data = params[:data]

    unless data.is_a?(Hash)
      raise BadRequest.new("Empty or invalid data submitted")
    end

    if requested_id.present?
      if !viewmodel.is_update_hash?(data)
        raise BadRequest.new("Not an update action: provided data doesn't represent an existing object")
      elsif viewmodel.update_id(data) != requested_id
        raise BadRequest.new("Invalid update action: provided data represents a different object")
      end
    elsif viewmodel.is_update_hash?
      raise BadRequest.new("Not a create action: provided data represents an existing object")
    end

    viewmodel.transaction do
      view = viewmodel.deserialize_from_view(data, **@view_options)
      render_viewmodel({ data: view }, **@view_options)
    end
  end

  # Methods to manipulate associations

  # List items associated with the target
  def index_associated(association_name)
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, eager_include: false, **@view_options)
      associated_views = target_view.load_associated(association_name, **@view_options)
      render_viewmodel({ data: associated_views }, **@view_options)
    end
  end

  # Deserialize items of the associated type and associate them with the target.
  # For a multiple association, can provide a single item to append to the
  # collection or an array of items to replace the collection.
  def create_associated(association_name)
    viewmodel.transaction do
      target_view = viewmodel.find(viewmodel_id, eager_include: false, **@view_options)

      data = params[:data]

      unless data.present? && (data.is_a?(Hash) || data.is_a?(Array))
        raise BadRequest.new("Empty or invalid data submitted")
      end

      assoc_view = target_view.deserialize_associated(association_name, data, **@view_options)
      render_viewmodel({ data: associated_views }, **@view_options)
    end
  end

  # Remove the association between the target and the provided item, garbage
  # collecting the item if specified as `dependent:` by the association.
  # Can't work for polymorphic associations.
  def destroy_associated(association_name)
    viewmodel.transaction do
      target_view = viewmodel.find(viewmodel_id, eager_include: false, **@view_options)
      associated_view = target_view.find_associated(association_name, associated_id(association_name), eager_include: false, **@view_options)

      target_view.delete_associated(association_name, associated_view, **@view_options)

      render_viewmodel({ data: nil })
    end
  end

  def viewmodel_id
    id_param_name = viewmodel.model_class.name.underscore + "_id"
    id_param = params[id_param_name]
    raise ArgumentError.new("Missing model id: '#{id_param_name}'") if id_param.nil?
    id_param
  end

  def associated_id(association_name)
    id_param_name = association_name.singularize + "_id"
    id_param = params[id_param_name]
    raise ArgumentError.new("Missing model id: '#{id_param_name}'") if id_param.nil?
    id_param
  end

  class_methods do
    def viewmodel
      unless instance_variable_defined?(:@viewmodel)
        # try to autodetect the viewmodel based on our name
        match = /(.*)Controller$/.match(self.name)
        raise ArgumentError.new("Could not auto-determine ViewModel from Controller name '#{self.name}'") if match.nil?
        self.viewmodel_name = match[1].singularize + "View"
      end
      @viewmodel
    end

    def association(association_name)
      @generated_routes_module.module_eval do
        define_method(:"create_#{association_name}") { create_associated(association_name)  }
        define_method(:"index_#{association_name}")  { index_associated(association_name)   }
        define_method(:"destroy_#{association_name}"){ destroy_associated(association_name) }
      end
    end

    private

    def viewmodel_name=(name)
      type = name.to_s.camelize.safe_constantize
      raise ArgumentError.new("Could not find ViewModel class '#{name}'") if type.nil?
      self.viewmodel = type
    end

    def viewmodel=(type)
      if instance_variable_defined?(:@viewmodel)
        raise ArgumentError.new("ViewModel class for Controller '#{self.name}' already set")
      end

      unless type < ActiveRecordViewModel
        raise ArgumentError.new("'#{type.inspect}' is not a valid ActiveRecordViewModel")
      end
      @viewmodel = type
    end
  end
end
