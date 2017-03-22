class ViewModel::AccessControlError < ViewModel::AbstractError
  attr_reader :nodes

  def initialize(detail, nodes = [])
    super(detail)
    @nodes = Array.wrap(nodes)
  end

  def status
    403
  end

  def metadata
    blame_metadata(nodes)
  end

  def code
    "AccessControl.Forbidden"
  end
end
