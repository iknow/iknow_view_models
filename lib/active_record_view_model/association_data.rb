# TODO consider rephrase scope for consistency
class ActiveRecordViewModel::AssociationData
  attr_reader :reflection
  delegate :polymorphic?, :collection?, :klass, :name, to: :reflection

  def initialize(reflection, viewmodel_classes, shared, optional, through_to, through_order_attr)
    @reflection         = reflection
    @shared             = shared
    @optional           = optional
    @through_to         = through_to
    @through_order_attr = through_order_attr

    if viewmodel_classes
      @viewmodel_classes = Array.wrap(viewmodel_classes)
    end

    if through?
      # TODO exception type
      raise "through associations must be has_many" unless reflection.macro == :has_many
    end
  end

  def viewmodel_classes
    # If we weren't given explicit viewmodel classes, try to work out from the
    # names. This should work unless the association is polymorphic.
    @viewmodel_classes ||=
      begin
        reflection = if through?
                       source_reflection
                     else
                       @reflection
                     end

        model_class = reflection.klass
        if model_class.nil?
          raise "Couldn't derivce target class for association '#{reflection.name}"
        end
        viewmodel_class = ActiveRecordViewModel.for_view_name(model_class.name) # TODO: improve error message to show it's looking for default name
        [viewmodel_class]
      end
  end

  private def model_to_viewmodel
    @model_to_viewmodel ||= viewmodel_classes.each_with_object({}) do |vm, h|
      h[vm.model_class] = vm
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
    vm_class = model_to_viewmodel[model_class]
    if vm_class.nil?
      raise ArgumentError.new("Can't find corresponding viewmodel to model '#{model_class.name}' for association '#{reflection.name}'")
    end
    vm_class
  end

  def viewmodel_class_for_name(type_name)
    vm_class = viewmodel_classes.detect { |vm| vm.can_deserialize_type?(type_name) }
    if vm_class.nil?
      raise ArgumentError.new("Can't find corresponding viewmodel accepting type '#{type_name}' for association '#{reflection.name}'")
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

  def through?
    @through_to.present?
  end

  def through_viewmodel
    @through_viewmodel ||= begin
      raise 'not a through association' unless through?

      # Join table viewmodel class

      # For A has_many B through T; where this association is defined on A

      # Copy into scope for new class block
      reflection         = self.reflection         # A -> T
      source_reflection  = self.source_reflection  # T -> B
      through_order_attr = @through_order_attr

      Class.new(ActiveRecordViewModel) do
        self.model_class = reflection.klass
        association source_reflection.name
        acts_as_list through_order_attr if through_order_attr
      end
    end
  end

  def source_reflection
    @source_reflection ||=
      reflection.klass.reflect_on_association(ActiveSupport::Inflector.singularize(@through_to))
  end

  def source_association_data
    self.through_viewmodel._association_data(@source_reflection.name)
  end
end
