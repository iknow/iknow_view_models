## Defines an access control discipline for a given action against a tree of
## viewmodels.
##
## Extends the basic AccessControl to offer different checking based on the view
## type and position in a viewmodel tree.
##
## Access checks for each given node type are specified at class level as
## `ComposedAccessControl`s, using `view` blocks. Checks that apply to all node
## types are specified in an `always` block.
##
## In addition, node types can be marked as a 'root'. Root types may permit and
## veto access to their non-root tree descendents with the additional access
## checks `root_children_{editable,visible}_if!` and `root_children_
## {editable,visible}_unless!`. The results of evaluating these checks on entry
## to the root node will be cached and used when evaluating `visible` and
## `editable` on children.
class ViewModel::AccessControl::Tree < ViewModel::AccessControl
  class << self
    attr_reader :view_policies

    def inherited(subclass)
      super
      subclass.initialize_as_tree_access_control
    end

    def initialize_as_tree_access_control
      @included_checkers = []
      @view_policies     = {}
      @env_vars          = []
      const_set(:AlwaysPolicy, Class.new(Node))
    end

    def include_from(ancestor)
      unless ancestor < ViewModel::AccessControl::Tree
        raise ArgumentError.new("Invalid ancestor: #{ancestor}")
      end

      @included_checkers << ancestor

      self::AlwaysPolicy.include_from(ancestor::AlwaysPolicy)
      ancestor.view_policies.each do |view_name, ancestor_policy|
        policy = find_or_create_policy(view_name)
        policy.include_from(ancestor_policy)
      end
    end

    def add_to_env(field_name)
      @env_vars << field_name
      self::AlwaysPolicy.add_to_env(field_name)
      view_policies.each_value { |p| p.add_to_env(field_name) }
    end

    # Definition language
    def view(view_name, &block)
      policy = find_or_create_policy(view_name)
      policy.instance_exec(&block)
    end

    def always(&block)
      self::AlwaysPolicy.instance_exec(&block)
    end

    ## implementation

    def create_policy(view_name)
      policy = Class.new(Node)
      # View names are not necessarily rails constants, but we want
      # `const_set` them so they show up in stack traces.
      mangled_name = view_name.tr('.', '_')
      const_set(:"#{mangled_name}Policy", policy)
      view_policies[view_name] = policy
      policy.include_from(self::AlwaysPolicy)
      @env_vars.each { |field| policy.add_to_env(field) }
      policy
    end

    def find_or_create_policy(view_name)
      view_policies.fetch(view_name) { create_policy(view_name) }
    end

    def inspect
      "#{super}(checks:\n#{@view_policies.values.map(&:inspect).join("\n")}\n#{self::AlwaysPolicy.inspect}\nincluded checkers: #{@included_checkers})"
    end
  end

  def initialize
    @always_policy_instance = self.class::AlwaysPolicy.new(self)
    @view_policy_instances  = self.class.view_policies.each_with_object({}) { |(name, policy), h| h[name] = policy.new(self) }
  end

  # Evaluation entry points
  def visible_check(view, context:)
    policy_instance_for(view).visible_check(view, context: context)
  end

  def editable_check(view, deserialize_context:)
    policy_instance_for(view).editable_check(view, deserialize_context: deserialize_context)
  end

  def valid_edit_check(view, deserialize_context:, changes:)
    policy_instance_for(view).valid_edit_check(view, deserialize_context: deserialize_context, changes: changes)
  end

  private

  def policy_instance_for(view)
    view_name = view.class.view_name
    @view_policy_instances.fetch(view_name) { @always_policy_instance }
  end

  # Mix-in for traversal contexts to support saving precalculated
  # child-editability/visibility for tree-based access control roots.
  module AccessControlRootMixin
    extend ActiveSupport::Concern

    RootData = Struct.new(:visibility, :editability)

    def descendent_access_control_data
      raise ArgumentError.new("Cannot access descendent access control data: node is not a root in this traversal") unless root?
      @descendent_access_control_data ||= RootData.new
    end

    def set_descendent_editability!(root_result)
      descendent_access_control_data.editability = root_result
    end

    def set_descendent_visibility!(root_result)
      descendent_access_control_data.visibility = root_result
    end
  end

  class Node < ViewModel::AccessControl::Composed
    class << self
      attr_reader :root_children_editable_ifs,
                  :root_children_editable_unlesses,
                  :root_children_visible_ifs,
                  :root_children_visible_unlesses

      def inherited(subclass)
        super
        subclass.initialize_as_node
      end

      def initialize_as_node
        @root = false
        @root_children_editable_ifs      = []
        @root_children_editable_unlesses = []
        @root_children_visible_ifs       = []
        @root_children_visible_unlesses  = []
      end

      def add_to_env(parent_field)
        delegate(parent_field, to: :@tree_access_control)
        super(parent_field)
      end

      def root_children_visible_if!(reason, &block)
        @root = true
        root_children_visible_ifs << new_permission_check(reason, &block)
      end

      def root_children_visible_unless!(reason, &block)
        @root = true
        root_children_visible_unlesses << new_permission_check(reason, &block)
      end

      def root_children_editable_if!(reason, &block)
        @root = true
        root_children_editable_ifs << new_permission_check(reason, &block)
      end

      def root_children_editable_unless!(reason, &block)
        @root = true
        root_children_editable_unlesses << new_permission_check(reason, &block)
      end

      def root?
        @root
      end

      alias requires_root? root?

      def inspect_checks
        checks = super
        if root?
          checks << "no root checks"
        else
          checks << "root_children_visible_if: #{root_children_visible_ifs.map(&:reason)}"            if root_children_visible_ifs.present?
          checks << "root_children_visible_unless: #{root_children_visible_unlesses.map(&:reason)}"   if root_children_visible_unlesses.present?
          checks << "root_children_editable_if: #{root_children_editable_ifs.map(&:reason)}"          if root_children_editable_ifs.present?
          checks << "root_children_editable_unless: #{root_children_editable_unlesses.map(&:reason)}" if root_children_editable_unlesses.present?
        end
        checks
      end
    end

    def initialize(tree_access_control)
      super()
      @tree_access_control = tree_access_control
    end

    def visible_check(view, context:)
      validate_root!(view, context)

      if context.root?
        save_root_visibility!(view, context: context)
        super
      else
        root_data = context.nearest_root.descendent_access_control_data
        root_data.visibility.merge { super }
      end
    end

    def editable_check(view, deserialize_context:)
      validate_root!(view, deserialize_context)

      if deserialize_context.root?
        save_root_editability!(view, deserialize_context: deserialize_context)
        super
      else
        root_data = deserialize_context.nearest_root.descendent_access_control_data
        root_data.editability.merge { super }
      end
    end

    private

    def validate_root!(view, context)
      if self.class.requires_root? && !context.root?
        raise RuntimeError.new("AccessControl instance for #{view.class.view_name} node requires root context but was visited in owned context.")
      end
    end

    def save_root_visibility!(view, context:)
      env = self.class.new_view_env(view, self, context)

      result = check_delegates(env,
                               self.class.each_check(:root_children_visible_ifs,      ->(a) { a.is_a?(Node) }),
                               self.class.each_check(:root_children_visible_unlesses, ->(a) { a.is_a?(Node) }))

      context.set_descendent_visibility!(result)
    end

    def save_root_editability!(view, deserialize_context:)
      env = self.class.new_edit_env(view, self, deserialize_context)

      result = check_delegates(env,
                               self.class.each_check(:root_children_editable_ifs,      ->(a) { a.is_a?(Node) }),
                               self.class.each_check(:root_children_editable_unlesses, ->(a) { a.is_a?(Node) }))

      deserialize_context.set_descendent_editability!(result)
    end
  end
end
