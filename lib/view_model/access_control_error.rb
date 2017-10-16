class ViewModel::AccessControlError < ViewModel::AbstractError
  attr_reader :nodes, :detail
  status 403
  code "AccessControl.Forbidden"

  def initialize(detail, nodes = [])
    @detail = detail
    @nodes = Array.wrap(nodes)
    super()
  end

  def meta
    blame_metadata(nodes)
  end
end
