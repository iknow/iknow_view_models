# frozen_string_literal: true

require 'renum'

# Callback hooks for viewmodel traversal contexts
module ViewModel::Callbacks
  extend ActiveSupport::Concern

  # Define the possible callback hooks and their required parameters.
  enum :Hook do
    BeforeVisit(:context)
    AfterVisit(:context)

    # The before deserialize hook is called when the viewmodel is visited during
    # deserialization. At this point we don't know whether deserialization will
    # be making any changes.
    BeforeDeserialize(:deserialize_context)

    # The on change hook is called if deserialization has visited the model and
    # intends to make changes. Keyword argument `changes` is a
    # ViewModel::Changes describing the intention. Callbacks on this hook may
    # not themselves make any changes to the model. ViewModels backed by a
    # transactional model such as AR may not have been saved, to allow the hook
    # to inspect initial values.
    OnChange(:deserialize_context, :changes)

    AfterDeserialize(:deserialize_context)

    attr_reader :context_name, :required_params

    def init(context_name, *other_params)
      @context_name = context_name
      @required_params = [context_name, *other_params]
    end

    def dsl_add_hook_name
      name.underscore
    end
  end

  # Placeholder for callbacks to invoked for all view types
  ALWAYS = "__always"

  # Callbacks classes may be inherited, including their callbacks.
  included do
    base_callbacks = {}
    define_singleton_method(:class_callbacks) { base_callbacks }
    define_singleton_method(:all_callbacks) { [base_callbacks] }
  end

  class_methods do
    def inherited(subclass)
      subclass_callbacks = {}
      subclass.define_singleton_method(:class_callbacks) { subclass_callbacks }
      subclass.define_singleton_method(:all_callbacks) { super() << subclass_callbacks }
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

      all_callbacks.each do |callbacks|
        if (hook_callbacks = callbacks[hook])
          hook_callbacks[view_name.to_s]&.each { |c| yield(c) }
          hook_callbacks[ALWAYS]&.each { |c| yield(c) }
        end
      end
    end

    private

    def add_callback(hook, view_name, &block)
      valid_hook!(hook)
      valid_hook_params!(hook, block)

      hook_callbacks = (class_callbacks[hook] ||= {})
      view_callbacks = (hook_callbacks[view_name.to_s] ||= [])
      view_callbacks << block
    end

    def valid_hook!(hook)
      unless hook.is_a?(Hook)
        raise ArgumentError.new("Invalid hook: '#{hook}'")
      end
    end

    def valid_hook_params!(hook, block)
      required_params = hook.required_params

      key_params, pos_params = block.parameters.partition do |type, _name|
        type == :key || type == :keyreq
      end

      unless pos_params.size == 1
        raise ArgumentError.new("Cannot add callback to hook #{hook}: "\
                                "must have exactly one positional parameter.")
      end

      key_param_names = key_params.map { |_type, name| name }
      unless (required_params.to_set ^ key_param_names).blank?
        raise ArgumentError.new("Cannot add callback to hook #{hook}: "\
                                "invalid keyword parameters #{key_param_names.inspect}, "\
                                "expected #{required_params.inspect}")
      end
    end
  end

  def run_callback(hook, node, **args)
    self.class.each_callback(hook, node.class.view_name) do |callback|
      self.instance_exec(node, **args, &callback)
    end
  end

  def self.wrap_serialize(viewmodel, context:)
    context.run_callback(ViewModel::Callbacks::Hook::BeforeVisit, viewmodel)
    val = yield
    context.run_callback(ViewModel::Callbacks::Hook::AfterVisit, viewmodel)
    val
  end

  def self.wrap_deserialize(viewmodel, deserialize_context:)
    wrap_serialize(viewmodel, context: deserialize_context) do
      deserialize_context.run_callback(ViewModel::Callbacks::Hook::BeforeDeserialize, viewmodel)
      val = yield
      deserialize_context.run_callback(ViewModel::Callbacks::Hook::AfterDeserialize, viewmodel)
      val
    end
  end
end
