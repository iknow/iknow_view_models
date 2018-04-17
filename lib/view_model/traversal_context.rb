# frozen_string_literal: true

require 'view_model/access_control/tree'

# Abstract base for Serialize and DeserializeContexts.
class ViewModel::TraversalContext
  class SharedContext
    attr_reader :access_control, :callbacks

    def initialize(access_control: ViewModel::AccessControl::Open.new, callbacks: [])
      @access_control = access_control
      # Access control is guaranteed to be run as the last callback, in case
      # other callbacks have side-effects.
      @callbacks = callbacks + [access_control]
    end
  end

  def self.shared_context_class
    SharedContext
  end

  attr_reader :shared_context
  delegate :access_control, :callbacks, to: :shared_context

  def self.new_child(*args)
    self.allocate.tap { |c| c.initialize_as_child(*args) }
  end

  def initialize(shared_context: nil, **shared_context_params)
    super()
    @shared_context     = shared_context || self.class.shared_context_class.new(**shared_context_params)
    @parent_context     = nil
    @parent_viewmodel   = nil
    @parent_association = nil
    @root               = true
  end

  # Overloaded constructor for initialization of descendent node contexts.
  # Shared context is the same, ancestry is established, and subclasses can
  # override to maintain other node-specific state.
  def initialize_as_child(shared_context:, parent_context:, parent_viewmodel:, parent_association:, root:)
    @shared_context     = shared_context
    @parent_context     = parent_context
    @parent_viewmodel   = parent_viewmodel
    @parent_association = parent_association
    @root               = root
  end

  def for_child(parent_viewmodel, association_name:, root: false, **rest)
    self.class.new_child(
      shared_context:     shared_context,
      parent_context:     self,
      parent_viewmodel:   parent_viewmodel,
      parent_association: association_name,
      root:               root,
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

  def run_callback(hook, view, **args)
    callbacks.each do |callback|
      callback.run_callback(hook, view, self, **args)
    end
  end

  def root?
    @root
  end

  def nearest_root
    if root?
      self
    else
      parent_context&.nearest_root
    end
  end

  def nearest_root_viewmodel
    if root?
      raise RuntimeError.new("Attempted to find nearest root from a root context. This is probably not what you wanted.")
    elsif parent_context.root?
      parent_viewmodel
    else
      parent_context.nearest_root
    end
  end
end
