# frozen_string_literal: true

class ViewModel::ActiveRecord::AssociationData
  class InvalidAssociation < RuntimeError; end

  attr_reader :association_name, :direct_reflection

  def initialize(owner:,
                 association_name:,
                 direct_association_name:,
                 indirect_association_name:,
                 target_viewmodels:,
                 external:,
                 through_order_attr:,
                 read_only:)
    @association_name = association_name

    @direct_reflection = owner.model_class.reflect_on_association(direct_association_name)
    if @direct_reflection.nil?
      raise InvalidAssociation.new("Association '#{direct_association_name}' not found in model '#{owner.model_class.name}'")
    end

    @indirect_association_name = indirect_association_name

    @read_only           = read_only
    @external            = external
    @through_order_attr  = through_order_attr
    @target_viewmodels   = target_viewmodels

    # Target models/reflections/viewmodels are lazily evaluated so that we can
    # safely express cycles.
    @initialized         = false
    @mutex               = Mutex.new
  end

  def lazy_initialize!
    @mutex.synchronize do
      return if @initialized

      if through?
        intermediate_model   = @direct_reflection.klass
        @indirect_reflection = load_indirect_reflection(intermediate_model, @indirect_association_name)
        target_reflection    = @indirect_reflection
      else
        target_reflection    = @direct_reflection
      end

      @viewmodel_classes =
        if @target_viewmodels.present?
          # Explicitly named
          @target_viewmodels.map { |v| resolve_viewmodel_class(v) }
        else
          # Infer name from name of model
          if target_reflection.polymorphic?
            raise InvalidAssociation.new(
                    'Cannot automatically infer target viewmodels from polymorphic association')
          end
          infer_viewmodel_class(target_reflection.klass)
        end

      @referenced = @viewmodel_classes.first.root?

      # Non-referenced viewmodels must be owned. For referenced viewmodels, we
      # own it if it points to us. Through associations aren't considered
      # `owned?`: while we do own the implicit direct viewmodel, we don't own
      # the target of the association.
      @owned = !@referenced || (target_reflection.macro != :belongs_to)

      unless @viewmodel_classes.all? { |v| v.root? == @referenced }
        raise InvalidAssociation.new('Invalid association target: mixed root and non-root viewmodels')
      end

      if external? && !@referenced
        raise InvalidAssociation.new('External associations must be to root viewmodels')
      end

      if through?
        unless @referenced
          raise InvalidAssociation.new('Through associations must be to root viewmodels')
        end

        @direct_viewmodel = build_direct_viewmodel(@direct_reflection, @indirect_reflection,
                                                   @viewmodel_classes, @through_order_attr)
      end

      @initialized = true
    end
  end

  def association?
    true
  end

  def referenced?
    lazy_initialize! unless @initialized
    @referenced
  end

  def nested?
    !referenced?
  end

  def owned?
    lazy_initialize! unless @initialized
    @owned
  end

  def shared?
    !owned?
  end

  def external?
    @external
  end

  def read_only?
    @read_only
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

  # The side of the immediate association that holds the pointer.
  def pointer_location
    case direct_reflection.macro
    when :belongs_to
      :local
    when :has_one, :has_many
      :remote
    end
  end

  def indirect_reflection
    lazy_initialize! unless @initialized
    @indirect_reflection
  end

  def direct_reflection_inverse(foreign_class = nil)
    if direct_reflection.polymorphic?
      direct_reflection.polymorphic_inverse_of(foreign_class)
    else
      direct_reflection.inverse_of
    end
  end

  def viewmodel_classes
    lazy_initialize! unless @initialized
    @viewmodel_classes
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
    @indirect_association_name.present?
  end

  def direct_viewmodel
    raise ArgumentError.new('not a through association') unless through?
    lazy_initialize! unless @initialized
    @direct_viewmodel
  end

  def collection?
    through? || direct_reflection.collection?
  end

  def indirect_association_data
    direct_viewmodel._association_data(indirect_reflection.name)
  end

  private

  # Through associations must always be to a root viewmodel, via an owned
  # has_many association to an intermediate model. A synthetic viewmodel is
  # created to represent this intermediate, but is used only internally by the
  # deserialization update operations, which directly understands the semantics
  # of through associations.
  def load_indirect_reflection(intermediate_model, indirect_association_name)
    indirect_reflection =
      intermediate_model.reflect_on_association(ActiveSupport::Inflector.singularize(indirect_association_name))

    if indirect_reflection.nil?
      raise InvalidAssociation.new(
              "Indirect association '#{@indirect_association_name}' not found in "\
              "intermediate model '#{intermediate_model.name}'")
    end

    unless direct_reflection.macro == :has_many
      raise InvalidAssociation.new('Through associations must be `has_many`')
    end

    indirect_reflection
  end

  def build_direct_viewmodel(direct_reflection, indirect_reflection, viewmodel_classes, through_order_attr)
    # Join table viewmodel class. For A has_many B through T; where this association is defined on A
    # direct_reflection   = A -> T
    # indirect_reflection = T -> B

    Class.new(ViewModel::ActiveRecord) do
      self.synthetic = true
      self.model_class = direct_reflection.klass
      self.view_name = direct_reflection.klass.name
      association indirect_reflection.name, viewmodels: viewmodel_classes
      acts_as_list through_order_attr if through_order_attr
    end
  end

  def resolve_viewmodel_class(v)
    case v
    when String, Symbol
      ViewModel::Registry.for_view_name(v.to_s)
    when Class
      v
    else
      raise InvalidAssociation.new("Invalid viewmodel class: #{v.inspect}")
    end
  end

  def infer_viewmodel_class(model_class)
    # If we weren't given explicit viewmodel classes, try to work out from the
    # names. This should work unless the association is polymorphic.
    if model_class.nil?
      raise InvalidAssociation.new("Couldn't derive target class for model association '#{target_reflection.name}'")
    end

    inferred_view_name = ViewModel::Registry.default_view_name(model_class.name)
    viewmodel_class = ViewModel::Registry.for_view_name(inferred_view_name) # TODO: improve error message to show it's looking for default name
    [viewmodel_class]
  end

  def model_to_viewmodel
    @model_to_viewmodel ||= viewmodel_classes.each_with_object({}) do |vm, h|
      h[vm.model_class] = vm
    end
  end

  def name_to_viewmodel
    @name_to_viewmodel ||= viewmodel_classes.each_with_object({}) do |vm, h|
      h[vm.view_name] = vm
      vm.view_aliases.each do |view_alias|
        h[view_alias] = vm
      end
    end
  end
end
