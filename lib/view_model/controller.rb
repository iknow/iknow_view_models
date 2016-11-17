require "view_model"

module ViewModel::Controller
  extend ActiveSupport::Concern

  class ApiErrorView < ViewModel
    attributes :status, :detail, :title, :code, :metadata

    def initialize(status: 400, detail: nil, title: nil, code: nil, metadata: {})
      super(status, detail, title, code, metadata)
    end

    def serialize_view(json, serialize_context: nil)
      json.status status
      json.detail detail if detail
      json.title  title  if title
      json.code   code   if code
      json.meta do
        ViewModel.serialize(metadata, json, serialize_context: serialize_context)
      end
    end

    def to_error
      ApiError.new([self], self.status)
    end
  end

  class ApiError < RuntimeError
    attr_reader :error_views, :status
    def initialize(error_views, status = nil)
      @error_views = Array.wrap(error_views)
      @status = status || @error_views.first.status
      super()
    end
  end

  class ExceptionView < ViewModel
    attributes :exception, :error_view

    def initialize(exception, status, metadata)
      error_view = ApiErrorView.new(status:   status,
                                    detail:   exception.message,
                                    code:     exception.try(:error_type),
                                    metadata: metadata)
      super(exception, error_view)
    end

    def serialize_view(json, serialize_context: nil)
      ViewModel.serialize(error_view, json, serialize_context: serialize_context)

      if Rails.env != 'production'
        json.exception do
          json.set! :class, exception.class.name
          json.backtrace exception.backtrace
          if cause = exception.cause
            json.cause do
              json.set! :class, cause.class.name
              json.backtrace cause.backtrace
            end
          end
        end
      end
    end
  end

  included do
    rescue_from ApiError,                        with: ->(ex){ render_errors(ex.error_views, ex.status) }
    rescue_from ViewModel::DeserializationError, with: ->(ex){ render_exception(ex, ex.http_status, metadata: ex.metadata) }
    rescue_from ViewModel::SerializationError,   with: ->(ex){ render_exception(ex, ex.http_status, metadata: ex.metadata) }
  end

  def render_viewmodel(viewmodel, status: nil, serialize_context: viewmodel.class.try(:new_serialize_context))
    render_jbuilder(status: status) do |json|
      json.data do
        ViewModel.serialize(viewmodel, json, serialize_context: serialize_context)
      end

      if serialize_context && serialize_context.has_references?
        json.references do
          serialize_context.serialize_references(json)
        end
      end
    end
  end

  def render_exception(exception, status = 500, metadata: {})
    render_errors([ExceptionView.new(exception, status, metadata)], status)
  end

  def render_errors(error_views, status = 500)
    render_jbuilder(status: status) do |json|
      json.errors Array.wrap(error_views) do |error_view|
        ViewModel.serialize(error_view, json)
      end
    end
  end

  protected

  def parse_viewmodel_updates
    update_hash = _extract_update_data(params.fetch(:data))
    refs        = _extract_param_hash(params.fetch(:references, {}))

    return update_hash, refs
  end

  private

  def _extract_update_data(data)
    if data.is_a?(Array)
      if data.blank?
        raise ViewModel::Controller::ApiErrorView.new(status: 400, detail: "No data submitted: #{data.inspect}").to_error
      end
      data.map { |el| _extract_param_hash(el) }
    else
      _extract_param_hash(data)
    end
  end

  def _extract_param_hash(data)
    case data
    when Hash
      data
    when ActionController::Parameters
      data.to_unsafe_h
    else
      raise ViewModel::Controller::ApiErrorView.new(status: 400, detail: "Invalid data submitted, expected hash: #{data.inspect}").to_error
    end
  end

  def render_jbuilder(status:)
    response = Jbuilder.encode do |json|
      yield json
    end

    ## jbuilder prevents this from working
    ##  - https://github.com/rails/jbuilder/issues/317
    ##  - https://github.com/rails/rails/issues/23923

    # render(json: response, status: status)

    render(plain: response, status: status, content_type: 'application/json')
  end
end
