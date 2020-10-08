class ViewModel::AccessControlError < ViewModel::AbstractErrorWithBlame
  attr_reader :detail

  status 403
  code 'AccessControl.Forbidden'

  def initialize(detail, nodes = [])
    @detail = detail
    super(nodes)
  end
end
