# frozen_string_literal: true

class ViewModel::Registry
  include Singleton

  DEFERRED_NAME = Object.new

  class << self
    delegate :for_view_name, :register, :default_view_name, :infer_model_class_name, :clear_removed_classes!,
             to: :instance
  end

  def initialize
    @lock = Monitor.new
    @viewmodel_classes_by_name = {}
    @deferred_viewmodel_classes = []
  end

  def for_view_name(name)
    raise ViewModel::DeserializationError::InvalidSyntax.new('ViewModel name cannot be nil') if name.nil?

    @lock.synchronize do
      # Resolve names for any deferred viewmodel classes
      resolve_deferred_classes

      viewmodel_class = @viewmodel_classes_by_name[name]

      if viewmodel_class.nil? || !(viewmodel_class < ViewModel)
        raise ViewModel::DeserializationError::UnknownView.new(name)
      end

      viewmodel_class
    end
  end

  def register(viewmodel, as: DEFERRED_NAME)
    @lock.synchronize do
      @deferred_viewmodel_classes << [viewmodel, as]
    end
  end

  def default_view_name(model_class_name)
    model_class_name.gsub('::', '.')
  end

  def infer_model_class_name(view_name)
    view_name.gsub('.', '::')
  end

  # For Rails hot code loading: ditch any classes that are not longer present at
  # their constant
  def clear_removed_classes!
    @lock.synchronize do
      resolve_deferred_classes
      @viewmodel_classes_by_name.delete_if do |_name, klass|
        !Kernel.const_defined?(klass.name)
      end
    end
  end

  private

  def resolve_deferred_classes
    until @deferred_viewmodel_classes.empty?
      vm, view_name = @deferred_viewmodel_classes.pop

      if vm.should_register?
        view_name = vm.view_name if view_name == DEFERRED_NAME
        @viewmodel_classes_by_name[view_name] = vm
      end
    end
  end
end
