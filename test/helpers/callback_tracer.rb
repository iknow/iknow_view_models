# frozen_string_literal: true

class CallbackTracer
  include ViewModel::Callbacks

  Visit = Struct.new(:hook, :view) do
    def inspect
      "#{hook.name}(#{view.to_reference})"
    end
  end

  attr_reader :hook_trace

  def initialize
    @hook_trace = []
  end

  ViewModel::Callbacks::Hook.each do |hook|
    send(hook.dsl_add_hook_name) do
      hook_trace << Visit.new(hook, view)
    end
  end

  def log!
    puts hook_trace.map { |t| [t.hook.name, t.view.class, t.view.model].inspect }
  end
end
