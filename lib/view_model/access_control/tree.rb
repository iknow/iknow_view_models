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
        policy = find_or_create_policy(view_name, root: ancestor_policy.root?)
        policy.include_from(ancestor_policy)
      end
    end

    def add_to_env(field_name)
      @env_vars << field_name
      self::AlwaysPolicy.add_to_env(field_name)
      view_policies.values.each { |p| p.add_to_env(field_name) }
    end

    # Definition language
    def view(view_name, root: false, &block)
      policy = find_or_create_policy(view_name, root: root)
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
      mangled_name = view_name.gsub(".", "_")
      const_set(:"#{mangled_name}Policy", policy)
      view_policies[view_name] = policy
      policy.include_from(self::AlwaysPolicy)
      @env_vars.each { |field| policy.add_to_env(field) }
      policy
    end

    def find_or_create_policy(view_name, root:)
      if (policy = view_policies[view_name])
        if policy.root? != root
          raise ArgumentError.new("Cannot create policy with root=#{root}: inconsistent with ancestors")
        end
      else
        policy = create_policy(view_name)
        policy.root! if root
      end
      policy
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

    def initialize(*)
      super
      @access_control_root_data = nil
    end

    def initialize_as_child(*)
      @access_control_root_data = nil
    end

    def access_control_root?
      @access_control_root_data.present?
    end

    def nearest_access_control_root_data
      @nearest_access_control_root_data ||=
        if access_control_root?
          @access_control_root_data
        else
          parent_context&.nearest_access_control_root_data
        end
    end

    def set_access_control_root_editability!(root_result)
      @access_control_root_data ||= RootData.new
      @access_control_root_data.editability = root_result
    end

    def set_access_control_root_visibility!(root_result)
      @access_control_root_data ||= RootData.new
      @access_control_root_data.visibility = root_result
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
        @root                            = false
        @root_children_editable_ifs      = []
        @root_children_editable_unlesses = []
        @root_children_visible_ifs       = []
        @root_children_visible_unlesses  = []
      end

      def root!
        @root = true
      end

      def root?
        @root
      end

      def add_to_env(parent_field)
        delegate(parent_field, to: :@tree_access_control)
        super(parent_field)
      end

      def root_children_visible_if!(reason, &block)
        raise ArgumentError.new("Cannot set child access control on non-root") unless root?
        @root_children_visible_ifs << new_permission_check(reason, &block)
      end

      def root_children_visible_unless!(reason, &block)
        raise ArgumentError.new("Cannot set child access control on non-root") unless root?
        @root_children_visible_unlesses << new_permission_check(reason, &block)
      end

      def root_children_editable_if!(reason, &block)
        raise ArgumentError.new("Cannot set child access control on non-root") unless root?
        @root_children_editable_ifs << new_permission_check(reason, &block)
      end

      def root_children_editable_unless!(reason, &block)
        raise ArgumentError.new("Cannot set child access control on non-root") unless root?
        @root_children_editable_unlesses << new_permission_check(reason, &block)
      end

      def inspect_checks
        checks = super
        checks.unshift("root: #{root?}")
        checks << "root_children_visible_if: #{@root_children_visible_ifs.map(&:reason)}"            if @root_children_visible_ifs.present?
        checks << "root_children_visible_unless: #{@root_children_visible_unlesses.map(&:reason)}"   if @root_children_visible_unlesses.present?
        checks << "root_children_editable_if: #{@root_children_editable_ifs.map(&:reason)}"          if @root_children_editable_ifs.present?
        checks << "root_children_editable_unless: #{@root_children_editable_unlesses.map(&:reason)}" if @root_children_editable_unlesses.present?
        checks
      end
    end

    def initialize(tree_access_control)
      super()
      @tree_access_control = tree_access_control
    end

    def visible_check(view, context:)
      if self.class.root?
        save_root_visibility!(view, context: context)
        super
      else
        if (root_data = context.nearest_access_control_root_data)
          root_data.visibility.merge { super }
        else
          super
        end
      end
    end

    def editable_check(view, deserialize_context:)
      if self.class.root?
        save_root_editability!(view, deserialize_context: deserialize_context)
        super
      else
        if (root_data = deserialize_context.nearest_access_control_root_data)
          root_data.editability.merge { super }
        else
          super
        end
      end
    end

    private

    def save_root_visibility!(view, context:)
      env = self.class.new_view_env(view, self, context)

      result = check_delegates(env,
                               self.class.each_check(:root_children_visible_ifs, ->(a){ a.is_a?(Node) }),
                               self.class.each_check(:root_children_visible_unlesses, ->(a){ a.is_a?(Node) }))

      context.set_access_control_root_visibility!(result)
    end

    def save_root_editability!(view, deserialize_context:)
      env = self.class.new_edit_env(view, self, deserialize_context)

      result = check_delegates(env,
                               self.class.each_check(:root_children_editable_ifs, ->(a){ a.is_a?(Node) }),
                               self.class.each_check(:root_children_editable_unlesses, ->(a){ a.is_a?(Node) }))

      deserialize_context.set_access_control_root_editability!(result)
    end
  end
end
