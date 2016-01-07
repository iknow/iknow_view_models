module ActiveRecordViewModel::Controller
  extend ActiveSupport::Concern

  included do
    CeregoViewModels.renderable!(self)
    delegate :viewmodel, to: self

    rescue_from StandardError,                               with: :render_error
    rescue_from ActiveRecord::RecordNotFound,                with: ->(ex){ render_error(ex, 404)}
    rescue_from ActiveRecordViewModel::DeserializationError, with: ->(ex){ render_error(ex, 400)}
  end

  def show(**view_options)
    model = viewmodel.table.includes(viewmodel.eager_includes(**view_options)).find(params[:id])
    view = viewmodel.new(model)
    render_viewmodel({ data: view }, **view_options)
  end

  def index(**view_options)
    models = viewmodel.table.includes(viewmodel.eager_includes(**view_options)).to_a
    views = models.map { |m| viewmodel.new(m) }
    render_viewmodel({ data: views }, **view_options)
  end

  def create(**view_options)
    deserialize(false, **view_options)
  end

  def update(**view_options)
    # TODO: don't just check that we're updating something, check that we're updating the specified thing.
    deserialize(true, **view_options)
  end

  private

  def deserialize(is_update, **view_options)
    data = params[:data]

    unless data.is_a?(Hash)
      raise DataServiceError.new(HTTP_BAD_REQUEST, "Empty or invalid data submitted")
    end

    if viewmodel.is_update_hash?(data) != is_update
      raise "data doesn't match create/update"
    end

    view = viewmodel.deserialize_from_view(data)
    render_viewmodel({ data: view }, **view_options)
  end

  # todo: differentiate errors so they're not all 500
  def render_error(exception, status = 500)
    render_viewmodel(ExceptionView.new(exception, status), status: status)
  end

  class ExceptionView < ViewModel
    attributes :exception, :status
    def serialize_view(json, **options)
      json.errors [exception] do |e|
        json.status status
        json.detail exception.message
        if Rails.env != 'production'
          json.set! :class, exception.class.name
          json.backtrace exception.backtrace
        end
      end
    end
  end


  class_methods do
    def viewmodel(v = nil)
      if v.present?
        raise ArgumentError.new("ViewModel for controller '#{self.name}' already set") if @viewmodel.present?
        if v.nil? || !(v < ActiveRecordViewModel)
          raise ArgumentError.new("Invalid ActiveRecordViewModel specified: '#{v.inspect}'")
        end
        @viewmodel = v
      end

      @viewmodel
    end
  end
end
