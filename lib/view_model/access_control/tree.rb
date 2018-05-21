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
## to the root node.object_id will be cached and used when evaluating `visible` and
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
    super()
    @always_policy_instance = self.class::AlwaysPolicy.new(self)
    @view_policy_instances  = self.class.view_policies.each_with_object({}) { |(name, policy), h| h[name] = policy.new(self) }
    @root_visibility_store  = {}
    @root_editability_store = {}
  end

  # Evaluation entry points
  def visible_check(traversal_env)
    policy_instance_for(traversal_env.view).visible_check(traversal_env)
  end

  def editable_check(traversal_env)
    policy_instance_for(traversal_env.view).editable_check(traversal_env)
  end

  def valid_edit_check(traversal_env)
    policy_instance_for(traversal_env.view).valid_edit_check(traversal_env)
  end

  def store_descendent_editability(view, descendent_editability)
    if @root_editability_store.has_key?(view.object_id)
      raise RuntimeError.new("Root access control data already saved for root")
    end
    @root_editability_store[view.object_id] = descendent_editability
  end

  def fetch_descendent_editability(view)
    @root_editability_store.fetch(view.object_id) do
      raise RuntimeError.new("No root access control data recorded for root")
    end
  end

  def store_descendent_visibility(view, descendent_visibility)
    if @root_visibility_store.has_key?(view.object_id)
      raise RuntimeError.new("Root access control data already saved for root")
    end
    @root_visibility_store[view.object_id] = descendent_visibility
  end

  def fetch_descendent_visibility(view)
    @root_visibility_store.fetch(view.object_id) do
      raise RuntimeError.new("No root access control data recorded for root")
    end
  end

  def cleanup_descendent_results(view)
    @root_visibility_store.delete(view.object_id)
    @root_editability_store.delete(view.object_id)
  end

  after_visit do
    cleanup_descendent_results(view) if context.root?
  end

  private

  def policy_instance_for(view)
    view_name = view.class.view_name
    @view_policy_instances.fetch(view_name) { @always_policy_instance }
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

    delegate :store_descendent_visibility, :fetch_descendent_visibility,
             :store_descendent_editability, :fetch_descendent_editability,
             to: :@tree_access_control

    def visible_check(traversal_env)
      view    = traversal_env.view
      context = traversal_env.context

      validate_root!(view, context)

      if context.root?
        save_root_visibility!(traversal_env)
        super
      else
        root_visibility = fetch_descendent_visibility(context.nearest_root_viewmodel)
        root_visibility.merge { super }
      end
    end

    def editable_check(traversal_env)
      view                = traversal_env.view
      deserialize_context = traversal_env.deserialize_context

      validate_root!(view, deserialize_context)

      if deserialize_context.root?
        save_root_editability!(traversal_env)
        super
      else
        root_editability = fetch_descendent_editability(deserialize_context.nearest_root_viewmodel)
        root_editability.merge { super }
      end
    end

    private

    def validate_root!(view, context)
      if self.class.requires_root? && !context.root?
        raise RuntimeError.new("AccessControl instance for #{view.class.view_name} node requires root context but was visited in owned context.")
      end
    end

    def save_root_visibility!(traversal_env)
      result = check_delegates(traversal_env,
                               self.class.each_check(:root_children_visible_ifs,      ->(a) { a.is_a?(Node) }),
                               self.class.each_check(:root_children_visible_unlesses, ->(a) { a.is_a?(Node) }))

      store_descendent_visibility(traversal_env.view, result)
    end

    def save_root_editability!(traversal_env)
      result = check_delegates(traversal_env,
                               self.class.each_check(:root_children_editable_ifs,      ->(a) { a.is_a?(Node) }),
                               self.class.each_check(:root_children_editable_unlesses, ->(a) { a.is_a?(Node) }))

      store_descendent_editability(traversal_env.view, result)
    end
  end
end
