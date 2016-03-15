require 'active_record_view_model/controller_base'
require 'active_record_view_model/nested_controller'

# Controller for accessing an ActiveRecordViewModel
# Provides for the following routes:
# GET    /models      #index
# POST   /models      #create
# GET    /models/:id  #show
# PATCH  /models/:id  #update
# PUT    /models/:id  #update
# DELETE /models/:id  #destroy

module ActiveRecordViewModel::Controller
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::ControllerBase

  included do
    attr_reader :view_options
    delegate :viewmodel, to: :class
  end

  def initialize(*)
    super
    @view_options = {}
  end

  def show(scope: nil)
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, scope: scope, **view_options)
      render_viewmodel({ data: view }, **view_options)
    end
  end

  def index(scope: nil)
    viewmodel.transaction do
      views = viewmodel.load(scope: scope, **view_options)
      render_viewmodel({ data: views }, **view_options)
    end
  end

  def create
    deserialize(nil)
  end

  def update
    deserialize(viewmodel_id)
  end

  def destroy(**view_options)
    viewmodel.transaction do
      view = viewmodel.find(viewmodel_id, eager_load: false, **view_options)
      view.destroy!(**view_options)
    end
    render_viewmodel({ data: nil })
  end

  protected

  def set_view_option(key, value)
    view_options[key] = value
  end

  private

  def viewmodel_id
    parse_integer_param(:id)
  end

  def deserialize(requested_id)
    data = params[:data]

    unless data.is_a?(Hash)
      raise ActiveRecordViewModel::ControllerBase::BadRequest.new("Empty or invalid data submitted")
    end

    if requested_id.present?
      if !viewmodel._is_update_hash?(data)
        raise ActiveRecordViewModel::ControllerBase::BadRequest.new("Not an update action: provided data doesn't represent an existing object")
      elsif viewmodel._update_id(data) != requested_id
        raise ActiveRecordViewModel::ControllerBase::BadRequest.new("Invalid update action: provided data represents a different object")
      end
    elsif viewmodel._is_update_hash?(data)
      raise ActiveRecordViewModel::ControllerBase::BadRequest.new("Not a create action: provided data represents an existing object")
    end

    viewmodel.transaction do
      view = viewmodel.deserialize_from_view(data, **view_options)
      render_viewmodel({ data: view }, **view_options)
    end
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

    def nested_in(owner, as:)
      include ActiveRecordViewModel::NestedController
      owner_name = owner.to_s.camelize + "View"
      self.owner_viewmodel = owner_name.safe_constantize
      raise ArgumentError.new("Could not find owner ViewModel class '#{owner_name}'") if owner_viewmodel.nil?
      self.association_name = as
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
