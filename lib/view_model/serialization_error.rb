class ViewModel::SerializationError < ViewModel::AbstractError
  attr_reader :detail
  status 400
  code 'SerializationError'

  def initialize(detail)
    @detail = detail
    super()
  end
end
