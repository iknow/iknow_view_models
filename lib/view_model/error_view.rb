# frozen_string_literal: true

require 'view_model/record'

# ViewModel for rendering ViewModel::AbstractErrors
class ViewModel::ErrorView < ViewModel::Record
  self.model_class = ViewModel::AbstractError
  self.view_name = 'Error'

  class ExceptionDetailView < ::ViewModel
    attributes :exception
    def serialize_view(json, serialize_context: nil)
      json.set! :class, exception.class.name
      json.backtrace exception.backtrace

      json.cause do
        cause = exception.cause
        next json.null! unless cause

        json.set! :class, cause.class.name
        json.backtrace cause.backtrace
      end

      json.context do
        next json.null! unless exception.respond_to?(:to_honeybadger_context)

        json.merge! cause.to_honeybadger_context
      end
    end
  end

  attributes :status, :detail, :title, :code, :meta
  attribute :causes, array: true, using: self
  attribute :exception, using: ExceptionDetailView

  # Ruby exceptions should never be serialized in production
  def serialize_exception(json, serialize_context:)
    if ViewModel::Config.show_cause_in_error_view
      super
    else
      json.exception nil
    end
  end
end
