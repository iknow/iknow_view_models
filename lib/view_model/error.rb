class ViewModel::AbstractError < StandardError
  def initialize(detail)
    super(detail)
  end

  def detail;   message; end
  def status;   nil;     end
  def title;    nil;     end
  def code;     nil;     end
  def metadata; {};      end

  def view
    ViewModel::Error::View.new(self)
  end
end

class ViewModel::Error < ViewModel::AbstractError
  attr_reader :status, :title, :code, :metadata

  def initialize(status: 400, detail: "ViewModel::Error", title: nil, code: nil, metadata: {})
    super(detail)

    @status   = status
    @title    = title
    @code     = code
    @metadata = metadata
  end

  class View < ::ViewModel
    attributes :error

    def serialize_view(json, serialize_context: nil)
      json.status error.status
      json.detail error.detail if error.detail
      json.title  error.title  if error.title
      json.code   error.code   if error.code

      json.meta do
        ViewModel.serialize(error.metadata, json, serialize_context: serialize_context)
      end

      if Rails.env != 'production'
        json.exception do
          ExceptionDetailView.new(error).serialize(json, serialize_context: serialize_context)
        end
      end
    end
  end

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
end
