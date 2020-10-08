# frozen_string_literal: true

require 'renum'
require 'safe_values'

# Callback hooks for viewmodel traversal contexts
module ViewModel::Callbacks
  extend ActiveSupport::Concern

  # Callbacks are run in the instance context of an Env class that wraps the
  # callbacks instance with additional instance method access to the view,
  # context and extra context-dependent parameters.
  module CallbackEnvContext
    def method_missing(method, *args, &block)
      if _callbacks.respond_to?(method, true)
        _callbacks.send(method, *args, &block)
      else
        super
      end
    end

    def respond_to_missing?(method, include_all = false)
      _callbacks.respond_to?(method, false) || super
    end
  end

  # Define the possible callback hooks and their required parameters.
  enum :Hook do
    BeforeVisit(:context)
    AfterVisit(:context)

    # The before deserialize hook is called when the viewmodel is visited during
    # deserialization. At this point we don't know whether deserialization will
    # be making any changes.
    BeforeDeserialize(:deserialize_context)

    # The BeforeValidate hook is called during deserialization immediately
    # before validating the viewmodel. For AR viewmodels, this is after
    # deserializing attributes and points-to associations, but before saving and
    # deserializing points-from associations. Callbacks on this hook may make
    # changes to the model, but must call the viewmodel's `*_changed!` methods
    # for any changes to viewmodel attributes/associations.
    BeforeValidate(:deserialize_context)

    # The on change hook is called when deserialization has visited the model
    # and made changes. Keyword argument `changes` is a ViewModel::Changes
    # describing the effects. Callbacks on this hook may not themselves make any
    # changes to the model. ViewModels backed by a transactional model such as
    # AR will have been saved once, allowing the hook to inspect changed model
    # values on `previous_changes`.
    OnChange(:deserialize_context, :changes)

    # The after-deserialize hook is called when leaving the viewmodel during
    # deserialization. The recorded ViewModel::Changes instance (which may have
    # no changes) is passed to the hook.
    AfterDeserialize(:deserialize_context, :changes)

    attr_reader :context_name, :required_params, :env_class

    def init(context_name, *other_params)
      @context_name    = context_name
      @required_params = other_params
      @env_class = Value.new(:_callbacks, :view, context_name, *other_params) do
        include CallbackEnvContext
        delegate :model, to: :view

        unless context_name == :context
          alias_method :context, context_name
        end

        # If we have any other params, generate a combined positional/keyword
        # constructor wrapper
        if other_params.present?
          params = other_params.map { |x| "#{x}:" }.join(', ')
          args   = other_params.join(', ')
          instance_eval(<<-SRC, __FILE__, __LINE__ + 1)
            def create(callbacks, view, context, #{params})
              self.new(callbacks, view, context, #{args})
            end
          SRC
        else
          def self.create(callbacks, view, context)
            self.new(callbacks, view, context)
          end
        end
      end
    end

    def dsl_add_hook_name
      name.underscore
    end

    def dsl_viewmodel_callback_method
      name.underscore.to_sym
    end
  end

  # Placeholder for callbacks to invoked for all view types
  ALWAYS = '__always'

  # Callbacks classes may be inherited, including their callbacks and
  # env method delegations.
  included do
    base_callbacks = {}
    define_singleton_method(:class_callbacks) { base_callbacks }
    define_singleton_method(:all_callbacks) do |&block|
      return to_enum(__method__) unless block

      block.call(base_callbacks)
    end
  end

  class_methods do
    def inherited(subclass)
      subclass_callbacks = {}
      subclass.define_singleton_method(:class_callbacks) { subclass_callbacks }
      subclass.define_singleton_method(:all_callbacks) do |&block|
        return to_enum(__method__) unless block

        super(&block)
        block.call(subclass_callbacks)
      end
    end

    # Add dsl methods to declare hooks in subclasses
    Hook.each do |hook|
      define_method(hook.dsl_add_hook_name) do |view_name = ALWAYS, &block|
        add_callback(hook, view_name, &block)
      end
    end

    def each_callback(hook, view_name)
      valid_hook!(hook)
      return to_enum(__method__, hook, view_name) unless block_given?

      all_callbacks do |callbacks|
        if (hook_callbacks = callbacks[hook])
          hook_callbacks[view_name.to_s]&.each { |c| yield(c) }
          hook_callbacks[ALWAYS]&.each { |c| yield(c) }
        end
      end
    end

    def updates_view?
      false
    end

    private

    def updates_view!
      define_singleton_method(:updates_view?) { true }
    end

    def add_callback(hook, view_name, &block)
      valid_hook!(hook)

      hook_callbacks = (class_callbacks[hook] ||= {})
      view_callbacks = (hook_callbacks[view_name.to_s] ||= [])
      view_callbacks << block
    end

    def valid_hook!(hook)
      unless hook.is_a?(Hook)
        raise ArgumentError.new("Invalid hook: '#{hook}'")
      end
    end
  end

  def run_callback(hook, view, context, **args)
    return if ineligible(view)

    callback_env = hook.env_class.create(self, view, context, **args)

    view_name = view.class.view_name
    self.class.each_callback(hook, view_name) do |callback|
      callback_env.instance_exec(&callback)
    end
  end

  def ineligible(view)
    # ARVM synthetic views are considered part of their association and as such
    # are not visited by callbacks. Eligibility exclusion is intended to be
    # library-internal: subclasses should not attempt to extend this.
    view.is_a?(ViewModel::ActiveRecord) && view.class.synthetic
  end

  def self.wrap_serialize(viewmodel, context:)
    context.run_callback(ViewModel::Callbacks::Hook::BeforeVisit, viewmodel)
    val = yield
    context.run_callback(ViewModel::Callbacks::Hook::AfterVisit, viewmodel)
    val
  end

  # Record changes made in the deserialization block so that they can be
  # provided to the AfterDeserialize hook.
  DeserializeHookControl = Struct.new(:changes) do
    alias_method :record_changes, :changes=
  end

  def self.wrap_deserialize(viewmodel, deserialize_context:)
    hook_control = DeserializeHookControl.new

    wrap_serialize(viewmodel, context: deserialize_context) do
      deserialize_context.run_callback(ViewModel::Callbacks::Hook::BeforeDeserialize,
                                       viewmodel)

      val = yield(hook_control)

      if hook_control.changes.nil?
        raise ViewModel::DeserializationError::Internal.new(
                'Internal error: changes not recorded for deserialization of viewmodel',
                viewmodel.blame_reference)
      end

      deserialize_context.run_callback(ViewModel::Callbacks::Hook::AfterDeserialize,
                                       viewmodel,
                                       changes: hook_control.changes)
      val
    end
  end
end
