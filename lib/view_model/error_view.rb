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
      if cause = exception.cause
        json.cause do
          json.set! :class, cause.class.name
          json.backtrace cause.backtrace
        end
      end
    end
  end

  attributes :status, :detail, :title, :code, :meta
  attribute :causes, array: true, using: self
  attribute :exception, using: ExceptionDetailView

  # Ruby exceptions should never be serialized in production
  def serialize_exception(json, serialize_context:)
    super unless Rails.env == 'production'
  end

  # Only serialize causes for aggregation errors.
  def serialize_causes(*)
    super if model.aggregation?
  end
end
