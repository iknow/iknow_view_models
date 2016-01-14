require 'active_record_view_model/controller_base'

module ActiveRecordViewModel::Controller
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::ControllerBase

  included do
    delegate :viewmodel, to: :class
  end

  def show(scope: nil, **view_options)
    viewmodel.transaction do
      view = viewmodel.find(params[:id], scope: scope, **view_options)
      render_viewmodel({ data: view }, **view_options)
    end
  end

  def index(scope: nil, **view_options)
    viewmodel.transaction do
      views = viewmodel.load(scope: scope, **view_options)
      render_viewmodel({ data: views }, **view_options)
    end
  end

  def create(**view_options)
    deserialize(nil, **view_options)
  end

  def update(**view_options)
    deserialize(params[:id], **view_options)
  end

  def destroy
    viewmodel.transaction do
      view = viewmodel.find(params[:id], eager_load: false)
      view.destroy!
    end
    render_viewmodel({ data: nil })
  end

  private

  def deserialize(requested_id, **view_options)
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
      view = viewmodel.deserialize_from_view(data)
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
