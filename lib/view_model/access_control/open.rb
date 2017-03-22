class ViewModel::AccessControl::Open < ViewModel::AccessControl
  def visible_check(view, context:)
    ViewModel::AccessControl::Result::PERMIT
  end

  def editable_check(view, deserialize_context:)
    ViewModel::AccessControl::Result::PERMIT
  end

  def valid_edit_check(view, deserialize_context:, changes:)
    ViewModel::AccessControl::Result::PERMIT
  end
end
