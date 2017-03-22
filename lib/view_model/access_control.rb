require 'view_model/access_control_error'

## Defines an access control discipline for a given action against a viewmodel.
##
## Access control is based around three edit check hooks: visible, editable and
## valid_edit. The visible determines whether a view can be seen. The editable
## check determines whether a view in its current state is eligible to be
## changed. The valid_edit change determines whether an attempted change is
## permitted. Each edit check returns a pair of boolean success and optional
## exception to raise.
class ViewModel::AccessControl
  Result = Struct.new(:permit, :error) do
    def initialize(permit, error: nil)
      raise ArgumentError.new("Successful AccessControl::Result may not have an error") if permit && error
      super(permit, error)
    end

    alias :permit? :permit

    # Merge this result with another access control result. Takes a block
    # returning a result, and returns a combined result for both tests. Access
    # is permitted if both results permit. Otherwise, access is denied with the
    # error value of the first denying Result.
    def merge(&block)
      if permit?
        yield
      else
        self
      end
    end
  end

  Result::PERMIT = Result.new(true).freeze
  Result::DENY   = Result.new(false).freeze

  # Check that the user is permitted to view the record in its current state, in
  # the given context.
  def visible_check(view, context:)
    Result::DENY
  end

  # Editable checks during deserialization are always a combination of
  # `editable_check` and `valid_edit_check`, which express the following
  # separate properties. `editable!` passes if both checks are successful.

  # Check that the record is eligible to be changed in its current state, in the
  # given context. During deserialization, this must be called before any edits
  # have taken place (thus checking against the initial state of the viewmodel),
  # and if edit is denied, an error must be raised if an edit is later
  # attempted. To be overridden by viewmodel implementations.
  def editable_check(view, deserialize_context:)
    Result::DENY
  end

  # Check that the attempted changes to this record are permitted in the given
  # context. During deserialization, this must be called once all edits have
  # been attempted. To be overridden by viewmodel implementations.
  def valid_edit_check(view, deserialize_context:, changes:)
    Result::DENY
  end

  # Implementations of deserialization that will potentially make changes to the
  # viewmodel or any of its descendents must call this on the unmodified
  # viewmodel to obtain an initial `editable_check` result before attempting to
  # apply their changes or recursing to children. This result must then be
  # passed to `editable!` as `initial_editability` after changes have been
  # applied.
  def initial_editability(view, deserialize_context:)
    return nil if ineligible(view)
    editable_check(view, deserialize_context: deserialize_context)
  end

  # Implementations of serialization and deserialization must call this
  # whenever a viewmodel is visited during serialization or deserialization.
  def visible!(view, context:)
    return if ineligible(view)

    result = visible_check(view, context: context)

    raise_if_error!(result) do
      message =
        if context.is_a?(ViewModel::DeserializeContext)
          "Attempt to deserialize into forbidden viewmodel '#{view.class.view_name}'"
        else
          "Attempt to serialize forbidden viewmodel '#{view.class.view_name}'"
        end

      ViewModel::AccessControlError.new(message, view.blame_reference)
    end
  end

  # Implementations of deserialization must call this when they know what
  # changes are to be made to the viewmodel. For viewmodels with transactional
  # backing models, the changes may be made in advance to give the edit checks
  # the opportunity to compare values. Must be called with the saved
  # `initial_editability` value if changes have been made.
  def editable!(view, initial_editability: nil, deserialize_context:, changes:)
    return if ineligible(view)

    initial_editability ||= editable_check(view, deserialize_context: deserialize_context)

    result = initial_editability.merge do
      valid_edit_check(view, deserialize_context: deserialize_context, changes: changes)
    end

    raise_if_error!(result) do
      ViewModel::AccessControlError.new(
        "Illegal edit to viewmodel '#{view.class.view_name}'",
        view.blame_reference)
    end
  end

  private

  def ineligible(view)
    # ARVM synthetic views are considered part of their association and as such
    # are not edit checked. Eligibility exclusion is intended to be
    # library-internal: subclasses should not attempt to extend this.
    view.is_a?(ViewModel::ActiveRecord) && view.class.synthetic
  end

  def raise_if_error!(result)
    raise (result.error || yield) unless result.permit?
  end
end

require 'view_model/access_control/open'
require 'view_model/access_control/read_only'
require 'view_model/access_control/composed'
require 'view_model/access_control/tree'
