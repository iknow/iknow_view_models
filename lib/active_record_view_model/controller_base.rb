module ActiveRecordViewModel::ControllerBase
  extend ActiveSupport::Concern

  class RenderError < Exception
    attr_accessor :code
    def initialize(msg, code)
      super(msg)
      self.code = code
    end
  end

  class BadRequest < RenderError
    def initialize(msg)
      super(msg, 400)
    end
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

  included do
    CeregoViewModels.renderable!(self)
    delegate :viewmodel, to: :class

    rescue_from StandardError,                               with: :render_error
    rescue_from RenderError,                                 with: ->(ex){ render_error(ex, ex.code) }
    rescue_from ActiveRecord::RecordNotFound,                with: ->(ex){ render_error(ex, 404)}
    rescue_from ActiveRecordViewModel::DeserializationError, with: ->(ex){ render_error(ex, 400)}
  end

  def render_error(exception, status = 500)
    render_viewmodel(ExceptionView.new(exception, status), status: status)
  end

end
