# Abstract base for renderable errors in ViewModel-based APIs. Errors of this
# type will be caught by ViewModel controllers and rendered in a standard format
# by ViewModel::ErrorView, which loosely follows errors in JSON-API.
class ViewModel::AbstractError < StandardError
  class << self
    # Brief DSL for quickly defining constant attribute values in subclasses
    [:detail, :status, :title, :code].each do |attribute|
      define_method(attribute) do |x|
        define_method(attribute){ x }
      end
    end
  end

  def initialize
    # `detail` is used to provide the exception message. However, it's not safe
    # to just override StandardError's `message` or `to_s` to call `detail`,
    # since some of Ruby's C implementation of Exceptions internally ignores
    # these methods and fetches the invisible internal `idMesg` attribute
    # instead. (!)
    #
    # This means that all fields necessary to derive the detail message must be
    # initialized before calling super().
    super(detail)
  end

  # Human-readable reason for use displaying this error.
  def detail
    "ViewModel::AbstractError"
  end

  # HTTP status code most appropriate for this error
  def status
    500
  end

  # Human-readable title for displaying this error
  def title
    nil
  end

  # Unique symbol identifying this error type
  def code
    "ViewModel.AbstractError"
  end

  # Additional information specific to this error type.
  def meta
    {}
  end

  # Some types of error may be aggregations over multiple causes
  def aggregation?
    false
  end

  # If so, the causes of this error (as AbstractErrors)
  def causes
    nil
  end

  # The exception responsible for this error. In most cases, that should be this
  # object, but sometimes an Error may be used to wrap an external exception.
  def exception
    self
  end

  def view
    ViewModel::ErrorView.new(self)
  end

  def to_s
    detail
  end

  protected



  def format_references(viewmodel_refs)
    viewmodel_refs.map do |viewmodel_ref|
      format_reference(viewmodel_ref)
    end
  end

  def format_reference(viewmodel_ref)
    {
      ViewModel::TYPE_ATTRIBUTE => viewmodel_ref.viewmodel_class.view_name,
      ViewModel::ID_ATTRIBUTE   => viewmodel_ref.model_id
    }
  end
end

# For errors associated with specific viewmodel nodes, include metadata
# describing the node to blame.
class ViewModel::AbstractErrorWithBlame < ViewModel::AbstractError
  attr_reader :nodes

  def initialize(blame_nodes)
    @nodes = Array.wrap(blame_nodes)
    super()
  end

  def meta
    {
      nodes: format_references(nodes)
    }
  end
end

# Abstract collection of errors
class ViewModel::AbstractErrorCollection < ViewModel::AbstractError
  attr_reader :causes

  def initialize(causes)
    @causes = Array.wrap(causes)
    unless @causes.present?
      raise ArgumentError.new("A collection must have at least one cause")
    end
    super()
  end

  def status
    causes.inject(causes.first.status) do |status, cause|
      if status == cause.status
        status
      else
        400
      end
    end
  end

  def detail
    "ViewModel::AbstractErrors: #{cause_details}"
  end

  def aggregation?
    true
  end

  def self.for_errors(errors)
    if errors.size == 1
      errors.first
    else
      self.new(errors)
    end
  end

  protected

  def cause_details
    causes.map(&:detail).join("; ")
  end
end

# Implementation of ViewModel::AbstractError with constructor parameters for
# each error data field.
class ViewModel::Error < ViewModel::AbstractError
  attr_reader :detail, :status, :title, :code, :meta

  def initialize(status: 400, detail: "ViewModel Error", title: nil, code: nil, meta: {})
    @detail = detail
    @status = status
    @title  = title
    @code   = code
    @meta   = meta
    super()
  end
end
