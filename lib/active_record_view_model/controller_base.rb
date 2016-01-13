module ActiveRecordViewModel::ControllerBase
  extend ActiveSupport::Concern

  included do
    CeregoViewModels.renderable!(self)
    delegate :viewmodel, to: self

    rescue_from StandardError,                               with: :render_error
    rescue_from ActiveRecord::RecordNotFound,                with: ->(ex){ render_error(ex, 404)}
    rescue_from ActiveRecordViewModel::DeserializationError, with: ->(ex){ render_error(ex, 400)}
  end

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
end
