class ActiveRecordViewModel::AssociationData
  attr_reader :reflection, :viewmodel_classes
  delegate :polymorphic?, :collection?, :klass, :name, to: :reflection

  def initialize(reflection, viewmodel_classes, shared, optional)
    if viewmodel_classes.nil?
      # If the association isn't polymorphic, we may be able to guess from the reflection
      model_class = reflection.klass
      if model_class.nil?
        raise ViewModel::DeserializationError.new("Couldn't derive target class for polymorphic association `#{reflection.name}`")
      end
      viewmodel_class = ActiveRecordViewModel.for_view_name(model_class.name) # TODO: improve error message to show it's looking for default name
      viewmodel_classes = [viewmodel_class]
    end

    @reflection        = reflection
    @viewmodel_classes = Array.wrap(viewmodel_classes)
    @shared            = shared
    @optional          = optional

    @model_to_viewmodel = viewmodel_classes.each_with_object({}) do |vm, h|
      h[vm.model_class] = vm
    end

    @name_to_viewmodel = viewmodel_classes.each_with_object({}) do |vm, h|
      h[vm.view_name] = vm
    end
  end

  def shared?
    @shared
  end

  def optional?
    @optional
  end

  def pointer_location # TODO name
    case reflection.macro
    when :belongs_to
      :local
    when :has_one, :has_many
      :remote
    end
  end

  def viewmodel_class_for_model(model_class)
    vm_class = @model_to_viewmodel[model_class]
    if vm_class.nil?
      raise ArgumentError.new("Can't find corresponding viewmodel to model '#{model_class.name}' for association '#{reflection.name}'")
    end
    vm_class
  end

  def viewmodel_class_for_name(name)
    vm_class = @name_to_viewmodel[name]
    if vm_class.nil?
      raise ArgumentError.new("Can't find corresponding viewmodel with name '#{name}' for association '#{reflection.name}'")
    end
    vm_class
  end

  def accepts?(viewmodel_class)
    viewmodel_classes.include?(viewmodel_class)
  end

  def viewmodel_class
    unless viewmodel_classes.size == 1
      raise ArgumentError.new("More than one possible class for association '#{reflection.name}'")
    end
    viewmodel_classes.first
  end
end
