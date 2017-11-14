require 'view_model/access_control/tree'

# Abstract base for Serialize and DeserializeContexts.
class ViewModel::TraversalContext
  class SharedContext
    attr_reader :access_control

    def initialize(access_control: ViewModel::AccessControl::Open.new)
      @access_control = access_control
    end
  end

  def self.shared_context_class
    SharedContext
  end

  attr_reader :shared_context
  delegate :access_control, to: :shared_context

  # Mechanism for marking nodes as access-control roots and saving their child-visibility
  include ViewModel::AccessControl::Tree::AccessControlRootMixin

  def self.new_child(*args)
    self.allocate.tap { |c| c.initialize_as_child(*args) }
  end

  def initialize(shared_context: nil, **shared_context_params)
    super()
    @shared_context   = shared_context || self.class.shared_context_class.new(**shared_context_params)
    @parent_context   = nil
    @parent_viewmodel = nil
    @parent_association = nil
  end

  # Overloaded constructor for initialization of descendent node contexts.
  # Shared context is the same, ancestry is established, and subclasses can
  # override to maintain other node-specific state.
  def initialize_as_child(shared_context:, parent_context:, parent_viewmodel:, parent_association:)
    super()
    @shared_context = shared_context
    @parent_context = parent_context
    @parent_viewmodel = parent_viewmodel
    @parent_association = parent_association
  end

  def for_child(parent_viewmodel, association_name:, **rest)
    self.class.new_child(shared_context: shared_context,
                         parent_context: self,
                         parent_viewmodel: parent_viewmodel,
                         parent_association: association_name,
                         **rest)
  end

  def parent_context(idx = 0)
    if idx == 0
      @parent_context
    else
      @parent_context&.parent_context(idx - 1)
    end
  end

  def parent_viewmodel(idx = 0)
    if idx == 0
      @parent_viewmodel
    else
      parent_context(idx - 1)&.parent_viewmodel
    end
  end

  def parent_association(idx = 0)
    if idx == 0
      @parent_association
    else
      parent_context(idx - 1)&.parent_association
    end
  end

  def parent_ref(idx = 0)
    parent_viewmodel(idx)&.to_reference
  end

  def visible!(view)
    access_control.visible!(view, context: self)
  end
end
