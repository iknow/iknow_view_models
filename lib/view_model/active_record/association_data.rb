# TODO consider rephrase scope for consistency
class ViewModel::ActiveRecord::AssociationData
  attr_reader :direct_reflection, :association_name

  def initialize(association_name, direct_reflection, viewmodel_classes, shared, optional, through_to, through_order_attr)
    @association_name   = association_name
    @direct_reflection  = direct_reflection
    @shared             = shared
    @optional           = optional
    @through_to         = through_to
    @through_order_attr = through_order_attr

    if viewmodel_classes
      @viewmodel_classes = Array.wrap(viewmodel_classes).map! do |v|
        case v
        when String, Symbol
          ViewModel::Registry.for_view_name(v.to_s)
        when Class
          v
        else
          raise ArgumentError.new("Invalid viewmodel class: #{v.inspect}")
        end
      end
    end

    if through?
      raise ArgumentError.new("Through associations must be `has_many`") unless direct_reflection.macro == :has_many
    end
  end

  # reflection for the target of this association: indirect if through, direct otherwise
  def target_reflection
    if through?
      indirect_reflection
    else
      direct_reflection
    end
  end

  def polymorphic?
    target_reflection.polymorphic?
  end

  def viewmodel_classes
    # If we weren't given explicit viewmodel classes, try to work out from the
    # names. This should work unless the association is polymorphic.
    @viewmodel_classes ||=
      begin
        model_class = target_reflection.klass
        if model_class.nil?
          raise "Couldn't derive target class for association '#{target_reflection.name}"
        end
        viewmodel_class = ViewModel::Registry.for_view_name(model_class.name) # TODO: improve error message to show it's looking for default name
        [viewmodel_class]
      end
  end

  private def model_to_viewmodel
    @model_to_viewmodel ||= viewmodel_classes.each_with_object({}) do |vm, h|
      h[vm.model_class] = vm
    end
  end

  private def name_to_viewmodel
    @name_to_viewmodel ||= viewmodel_classes.each_with_object({}) do |vm, h|
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
    case direct_reflection.macro
    when :belongs_to
      :local
    when :has_one, :has_many
      :remote
    end
  end

  def viewmodel_class_for_model(model_class)
    model_to_viewmodel[model_class]
  end

  def viewmodel_class_for_model!(model_class)
    vm_class = viewmodel_class_for_model(model_class)
    if vm_class.nil?
      raise ArgumentError.new(
              "Invalid viewmodel model for association '#{target_reflection.name}': '#{model_class.name}'")
    end
    vm_class
  end

  def viewmodel_class_for_name(name)
    name_to_viewmodel[name]
  end

  def viewmodel_class_for_name!(name)
    vm_class = viewmodel_class_for_name(name)
    if vm_class.nil?
      raise ArgumentError.new(
              "Invalid viewmodel name for association '#{target_reflection.name}': '#{name}'")
    end
    vm_class
  end

  def accepts?(viewmodel_class)
    viewmodel_classes.include?(viewmodel_class)
  end

  def viewmodel_class
    unless viewmodel_classes.size == 1
      raise ArgumentError.new("More than one possible class for association '#{target_reflection.name}'")
    end
    viewmodel_classes.first
  end

  def through?
    @through_to.present?
  end

  def direct_viewmodel
    @direct_viewmodel ||= begin
      raise 'not a through association' unless through?

      # Join table viewmodel class

      # For A has_many B through T; where this association is defined on A

      # Copy into scope for new class block
      direct_reflection   = self.direct_reflection    # A -> T
      indirect_reflection = self.indirect_reflection  # T -> B
      through_order_attr  = @through_order_attr
      viewmodel_classes   = self.viewmodel_classes

      Class.new(ViewModel::ActiveRecord) do
        self.synthetic = true
        self.model_class = direct_reflection.klass
        self.debug_name = direct_reflection.klass.name
        association indirect_reflection.name, shared: true, optional: false, viewmodels: viewmodel_classes
        acts_as_list through_order_attr if through_order_attr
      end
    end
  end

  def indirect_reflection
    @indirect_reflection ||=
      direct_reflection.klass.reflect_on_association(ActiveSupport::Inflector.singularize(@through_to))
  end

  def collection?
    through? || direct_reflection.collection?
  end

  def indirect_association_data
    direct_viewmodel._association_data(indirect_reflection.name)
  end
end
