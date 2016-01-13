require 'active_record_view_model/controller_base'

module ActiveRecordViewModel::Controller
  extend ActiveSupport::Concern
  include ActiveRecordViewModel::ControllerBase

  included do
    delegate :viewmodel, to: self
  end

  def show(**view_options)
    model = viewmodel.model_scope(**view_options).find(params[:id])
    view = viewmodel.new(model)
    render_viewmodel({ data: view }, **view_options)
  end

  def index(scope: nil, **view_options)
    models = viewmodel.model_scope(**view_options).merge(scope).to_a
    views = models.map { |m| viewmodel.new(m) }
    render_viewmodel({ data: views }, **view_options)
  end

  def create(**view_options)
    deserialize(nil, **view_options)
  end

  def update(**view_options)
    deserialize(params[:id], **view_options)
  end

  def delete
    model = viewmodel.model_scope(**view_options).find(params[:id])
    view = viewmodel.new(model)
    view.destroy!
  end

  private

  def deserialize(requested_id, **view_options)
    data = params[:data]

    unless data.is_a?(Hash)
      raise DataServiceError.new(HTTP_BAD_REQUEST, "Empty or invalid data submitted")
    end

    if requested_id.present?
      raise "not an update" unless viewmodel.is_update_hash?(data)
      raise "incorrect update" unless viewmodel.update_id(data) == requested_id
    else
      raise "not a create" if viewmodel.is_update_hash?
    end

    view = viewmodel.deserialize_from_view(data)
    render_viewmodel({ data: view }, **view_options)
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
