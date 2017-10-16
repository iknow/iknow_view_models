class ViewModel::Registry
  include Singleton

  DEFERRED_NAME = Object.new

  class << self
    delegate :for_view_name, :register, to: :instance
  end

  def initialize
    @viewmodel_classes_by_name  = Concurrent::Map.new
    @deferred_viewmodel_classes = Concurrent::Array.new
  end

  def for_view_name(name)
    raise ViewModel::DeserializationError::InvalidSyntax.new("ViewModel name cannot be nil") if name.nil?

    # Resolve names for any deferred viewmodel classes
    until @deferred_viewmodel_classes.empty? do
      vm, view_name = @deferred_viewmodel_classes.pop

      if vm.should_register?
        view_name = vm.view_name if view_name == DEFERRED_NAME
        @viewmodel_classes_by_name[view_name] = vm
      end
    end

    viewmodel_class = @viewmodel_classes_by_name[name]

    if viewmodel_class.nil? || !(viewmodel_class < ViewModel)
      raise ViewModel::DeserializationError::UnknownView.new(name)
    end

    viewmodel_class
  end

  def register(viewmodel, as: DEFERRED_NAME)
    @deferred_viewmodel_classes << [viewmodel, as]
  end
end
