# frozen_string_literal: true

## Provides access control as a combination of `x_if!` and `x_unless!` checks
## for each access check (visible, editable, edit_valid). An action is permitted
## if at least one `if` check and no `unless` checks succeed. For example:
##    edit_valid_if!("logged in as specified user") { ... }
##    edit_valid_unless!("user is on fire") { ... }
class ViewModel::AccessControl::Composed < ViewModel::AccessControl
  ComposedResult = Struct.new(:allow, :veto, :allow_error, :veto_error) do
    def initialize(allow, veto, allow_error, veto_error)
      raise ArgumentError.new('Non-vetoing result may not have a veto error') if veto_error  && !veto
      raise ArgumentError.new('Allowing result may not have a allow error')   if allow_error && allow

      super
    end

    def permit?
      !veto && allow
    end

    def error
      case
      when veto   then veto_error
      when !allow then allow_error
      else nil
      end
    end

    # Merge this composed result with another. `allow`s widen and `veto`es narrow.
    def merge(&_block)
      if self.veto
        self
      else
        other = yield

        new_allow = self.allow || other.allow

        new_allow_error =
          case
          when new_allow
            nil
          when mergeable_error?(self.allow_error) && mergeable_error?(other.allow_error)
            self.allow_error.merge(other.allow_error)
          else
            self.allow_error || other.allow_error
          end

        ComposedResult.new(new_allow, other.veto, new_allow_error, other.veto_error)
      end
    end

    private

    def mergeable_error?(err)
      err&.is_a?(NoRequiredConditionsError)
    end
  end

  PermissionsCheck = Struct.new(:location, :reason, :error_type, :checker) do
    def name
      "#{reason} (#{location})"
    end

    def check(env)
      env.instance_exec(&self.checker)
    end
  end

  # Error type when no `if` conditions succeed.
  class NoRequiredConditionsError < ViewModel::AccessControlError
    attr_reader :reasons

    def initialize(nodes, reasons)
      super('Action not permitted because none of the possible conditions were met.', nodes)
      @reasons = reasons
    end

    def meta
      super.merge(conditions: @reasons.to_a)
    end

    def merge(other)
      NoRequiredConditionsError.new(nodes | other.nodes,
                                    Lazily.concat(reasons, other.reasons).uniq)
    end
  end

  class << self
    attr_reader :edit_valid_ifs,
                :edit_valid_unlesses,
                :editable_ifs,
                :editable_unlesses,
                :visible_ifs,
                :visible_unlesses

    def inherited(subclass)
      super
      subclass.initialize_as_composed_access_control
    end

    def initialize_as_composed_access_control
      @included_checkers = []

      @edit_valid_ifs      = []
      @edit_valid_unlesses = []

      @editable_ifs        = []
      @editable_unlesses   = []

      @visible_ifs         = []
      @visible_unlesses    = []
    end

    ## Configuration API
    def include_from(ancestor)
      unless ancestor < ViewModel::AccessControl::Composed
        raise ArgumentError.new("Invalid ancestor: #{ancestor}")
      end

      @included_checkers << ancestor
    end

    def visible_if!(reason, &block)
      @visible_ifs         << new_permission_check(reason, &block)
    end

    def visible_unless!(reason, &block)
      @visible_unlesses    << new_permission_check(reason, &block)
    end

    def editable_if!(reason, &block)
      @editable_ifs        << new_permission_check(reason, &block)
    end

    def editable_unless!(reason, &block)
      @editable_unlesses   << new_permission_check(reason, &block)
    end

    def edit_valid_if!(reason, &block)
      @edit_valid_ifs      << new_permission_check(reason, &block)
    end

    def edit_valid_unless!(reason, &block)
      @edit_valid_unlesses << new_permission_check(reason, &block)
    end

    ## Implementation

    def new_permission_check(reason, error_type: ViewModel::AccessControlError, &block)
      PermissionsCheck.new(self.name&.demodulize, reason, error_type, block)
    end

    def each_check(check_name, include_ancestor = nil)
      return enum_for(:each_check, check_name, include_ancestor) unless block_given?

      self.public_send(check_name).each { |x| yield x }

      visited = Set.new
      @included_checkers.each do |ancestor|
        next unless visited.add?(ancestor)
        next if include_ancestor && !include_ancestor.call(ancestor)

        ancestor.each_check(check_name) { |x| yield x }
      end
    end

    def inspect
      s = super + '('
      s += inspect_checks.join(', ')
      s += " includes checkers: #{@included_checkers.inspect}" if @included_checkers.present?
      s += ')'
      s
    end

    def inspect_checks
      checks = []
      checks << "visible_if: #{@visible_ifs.map(&:reason)}"                if @visible_ifs.present?
      checks << "visible_unless: #{@visible_unlesses.map(&:reason)}"       if @visible_unlesses.present?
      checks << "editable_if: #{@editable_ifs.map(&:reason)}"              if @editable_ifs.present?
      checks << "editable_unless: #{@editable_unlesses.map(&:reason)}"     if @editable_unlesses.present?
      checks << "edit_valid_if: #{@edit_valid_ifs.map(&:reason)}"          if @edit_valid_ifs.present?
      checks << "edit_valid_unless: #{@edit_valid_unlesses.map(&:reason)}" if @edit_valid_unlesses.present?
      checks
    end
  end

  # final
  def visible_check(traversal_env)
    check_delegates(traversal_env, self.class.each_check(:visible_ifs), self.class.each_check(:visible_unlesses))
  end

  # final
  def editable_check(traversal_env)
    check_delegates(traversal_env, self.class.each_check(:editable_ifs), self.class.each_check(:editable_unlesses))
  end

  # final
  def valid_edit_check(traversal_env)
    check_delegates(traversal_env, self.class.each_check(:edit_valid_ifs), self.class.each_check(:edit_valid_unlesses))
  end

  protected

  def check_delegates(env, ifs, unlesses)
    veto, veto_error = detect_veto(env, unlesses)
    allow, allow_error = detect_allow(env, ifs)

    ComposedResult.new(allow, veto, allow_error, veto_error)
  end

  private

  def detect_veto(env, checkers)
    checkers.each do |checker|
      result = checker.check(env)
      next unless result

      error =
        if result.is_a?(StandardError)
          result
        else
          checker.error_type.new('Action not permitted because: ' +
                                 checker.reason,
                                 env.view.blame_reference)
        end

      # short-circuit exit with failure
      return true, error
    end

    return false, nil
  end

  def detect_allow(env, checkers)
    error = nil

    checkers.each do |checker|
      result = checker.check(env)
      next unless result

      if result.is_a?(StandardError)
        error ||= result
      else
        # short-circuit exit with success
        return true, nil
      end
    end

    error ||= NoRequiredConditionsError.new(
      env.view.blame_reference,
      checkers.map(&:name))

    return false, error
  end
end
