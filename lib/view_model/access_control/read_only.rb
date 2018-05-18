class ViewModel::AccessControl::ReadOnly < ViewModel::AccessControl
  def visible_check(_traversal_env)
    ViewModel::AccessControl::Result::PERMIT
  end

  def editable_check(_traversal_env)
    ViewModel::AccessControl::Result::DENY
  end

  def valid_edit_check(_traversal_env)
    ViewModel::AccessControl::Result::DENY
  end
end
