require 'iknow_view_models'

class TestAccessControl < ViewModel::AccessControl
  attr_accessor :editable_checks, :visible_checks

  def initialize(can_view, can_edit, can_change)
    super()
    @can_edit          = can_edit
    @can_view          = can_view
    @can_change        = can_change
    @editable_checks   = []
    @visible_checks    = []
    @valid_edit_checks = []
  end

  # Collect

  def editable_check(traversal_env)
    @editable_checks << traversal_env.view.to_reference
    ViewModel::AccessControl::Result.new(@can_edit)
  end

  def valid_edit_check(traversal_env)
    ref = traversal_env.view.to_reference
    @valid_edit_checks << [ref, traversal_env.changes]
    ViewModel::AccessControl::Result.new(@can_change)
  end

  def visible_check(traversal_env)
    @visible_checks << traversal_env.view.to_reference
    ViewModel::AccessControl::Result.new(@can_view)
  end

  # Query (also see attr_accessors)

  def valid_edit_refs
    @valid_edit_checks.map { |ref, _changes| ref }
  end

  def valid_edit_changes(ref)
    all = all_valid_edit_changes(ref)
    raise "Expected single change for ref '#{ref}'; found #{all}" unless all.size == 1

    all.first
  end

  def all_valid_edit_changes(ref)
    @valid_edit_checks
      .select { |cref, _changes| cref == ref }
      .map    { |_cref, changes| changes }
  end

  def was_edited?(ref)
    all_valid_edit_changes(ref).present?
  end
end
