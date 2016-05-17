# TODO consider rephrase scope for consistency
class ActiveRecordViewModel::AssociationData
  attr_reader :direct_reflection
  delegate :polymorphic?, :klass, :name, to: :direct_reflection
  alias reflection direct_reflection

  def initialize(direct_reflection, viewmodel_classes, shared, optional, through_to, through_order_attr)
    @direct_reflection  = direct_reflection
    @shared             = shared
    @optional           = optional
    @through_to         = through_to
    @through_order_attr = through_order_attr

    if viewmodel_classes
      @viewmodel_classes = Array.wrap(viewmodel_classes)
    end

    if through?
      # TODO exception type
      raise "through associations must be has_many" unless direct_reflection.macro == :has_many
    end
  end

  def viewmodel_classes
    # If we weren't given explicit viewmodel classes, try to work out from the
    # names. This should work unless the association is polymorphic.
    @viewmodel_classes ||=
      begin
        reflection = if through?
                       indirect_reflection
                     else
                       @direct_reflection
                     end

        model_class = reflection.klass
        if model_class.nil?
          raise "Couldn't derive target class for association '#{reflection.name}"
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
      direct_reflection   = self.direct_reflection    # A -> T
      indirect_reflection = self.indirect_reflection  # T -> B
      through_order_attr  = @through_order_attr
      viewmodel_classes   = self.viewmodel_classes

      Class.new(ActiveRecordViewModel) do
        self.model_class = direct_reflection.klass
        association indirect_reflection.name, shared: true, optional: false, viewmodels: viewmodel_classes
        acts_as_list through_order_attr if through_order_attr
      end
    end
  end

  def indirect_reflection
    @indirect_reflection ||=
      reflection.klass.reflect_on_association(ActiveSupport::Inflector.singularize(@through_to))
  end

  def collection?
    through? || reflection.collection?
  end

  def indirect_association_data
    through_viewmodel._association_data(indirect_reflection.name)
  end
end
