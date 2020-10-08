# frozen_string_literal: true

require 'view_model/access_control/tree'

# Abstract base for Serialize and DeserializeContexts.
class ViewModel::TraversalContext
  class SharedContext
    attr_reader :access_control, :callbacks

    def initialize(access_control: ViewModel::AccessControl::Open.new, callbacks: [])
      @access_control = access_control
      # Access control is guaranteed to be run after callbacks that may have
      # side-effects on the view.
      pre_callbacks, post_callbacks = callbacks.partition { |c| c.class.updates_view? }
      @callbacks = pre_callbacks + [access_control] + post_callbacks
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
  def initialize_as_child(shared_context:, parent_context:, parent_viewmodel:, parent_association:)
    @shared_context     = shared_context
    @parent_context     = parent_context
    @parent_viewmodel   = parent_viewmodel
    @parent_association = parent_association
    @root               = false
  end

  def for_child(parent_viewmodel, association_name:, **rest)
    self.class.new_child(
      shared_context:     shared_context,
      parent_context:     self,
      parent_viewmodel:   parent_viewmodel,
      parent_association: association_name,
      **rest)
  end

  # Obtain a semi-independent context for descending through a shared reference:
  # keep the same shared context, but drop any tree location specific local
  # context (since a shared reference could equally have been reached via any
  # parent)
  def for_references
    self.class.new(shared_context: shared_context)
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
    # Run in-viewmodel callback hooks before context hooks, as they are
    # permitted to alter the model.
    if view.respond_to?(hook.dsl_viewmodel_callback_method)
      view.public_send(hook.dsl_viewmodel_callback_method, hook.context_name => self, **args)
    end

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
      raise RuntimeError.new('Attempted to find nearest root from a root context. This is probably not what you wanted.')
    elsif parent_context.root?
      parent_viewmodel
    else
      parent_context.nearest_root_viewmodel
    end
  end
end
