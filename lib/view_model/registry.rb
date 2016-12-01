class ViewModel::Registry
  include Singleton

  class << self
    delegate :for_view_name, :register, to: :instance
  end

  def initialize
    @viewmodel_classes_by_name  = Concurrent::Map.new
    @deferred_viewmodel_classes = Concurrent::Array.new
  end

  def for_view_name(name)
    raise ViewModel::DeserializationError.new("ViewModel name cannot be nil") if name.nil?

    # Resolve names for any deferred viewmodel classes
    until @deferred_viewmodel_classes.empty? do
      vm = @deferred_viewmodel_classes.pop

      if vm.should_register?
        vm.view_names.each do |name|
          @viewmodel_classes_by_name[name] = vm
        end
      end
    end

    viewmodel_class = @viewmodel_classes_by_name[name]

    if viewmodel_class.nil? || !(viewmodel_class < ViewModel)
      raise ViewModel::DeserializationError.new("ViewModel class for view name '#{name}' not found")
    end

    viewmodel_class
  end

  def register(viewmodel)
    @deferred_viewmodel_classes << viewmodel
  end
end
