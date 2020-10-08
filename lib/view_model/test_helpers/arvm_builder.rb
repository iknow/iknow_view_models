class ViewModel::TestHelpers::ARVMBuilder
  attr_reader :name, :model, :viewmodel, :namespace

  # Building an ARVM requires three blocks, to define schema, model and
  # viewmodel. Support providing these either in an spec argument or as a
  # dsl-style builder.
  Spec = Struct.new(:schema, :model, :viewmodel)
  class Spec
    def initialize(schema:, model:, viewmodel:)
      super(schema, model, viewmodel)
    end

    def merge(schema: nil, model: nil, viewmodel: nil)
      this_schema    = self.schema
      this_model     = self.model
      this_viewmodel = self.viewmodel

      Spec.new(
        schema: ->(t) do
          this_schema.(t)
          schema&.(t)
        end,
        model: ->(m) do
          m.class_eval(&this_model)
          model.try { |b| m.class_eval(&b) }
        end,
        viewmodel: ->(v) do
          v.class_eval(&this_viewmodel)
          viewmodel.try { |b| v.class_eval(&b) }
        end)
    end
  end

  def initialize(name, model_base: ApplicationRecord, viewmodel_base: ViewModelBase, namespace: Object, spec: nil, &block)
    @model_base = model_base
    @viewmodel_base = viewmodel_base
    @namespace = namespace
    @name = name.to_s.camelize
    @no_viewmodel = false

    if spec
      define_schema(&spec.schema)
      define_model(&spec.model)
      define_viewmodel(&spec.viewmodel)
    else
      instance_eval(&block)
    end

    raise 'Model not created in ARVMBuilder'     unless model
    raise 'Schema not created in ARVMBuilder'    unless model.table_exists?
    raise 'ViewModel not created in ARVMBuilder' unless (viewmodel || @no_viewmodel)

    # Force the realization of the view model into the library's lookup
    # table. If this doesn't happen the library may have conflicting entries in
    # the deferred table, and will allow viewmodels to leak between tests.
    unless @no_viewmodel || !(@viewmodel < ViewModel::Record)
      resolved = ViewModel::Registry.for_view_name(viewmodel.view_name)
      raise 'Failed to register expected new class!' unless resolved == @viewmodel
    end
  end

  def teardown
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{name.underscore.pluralize} CASCADE")
    namespace.send(:remove_const, name)
    namespace.send(:remove_const, viewmodel_name) if viewmodel
    # prevent cached old class from being used to resolve associations
    ActiveSupport::Dependencies::Reference.clear!
  end

  private

  def viewmodel_name
    self.name + 'View'
  end

  def define_schema(&block)
    table_name = name.underscore.pluralize
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{table_name} CASCADE")
    ActiveRecord::Schema.define do
      self.verbose = false
      create_table(table_name, &block)
    end
  end

  def define_model(&block)
    model_name = name
    _namespace = namespace
    @model = Class.new(@model_base) do |c|
      raise "Model already defined: #{model_name}" if _namespace.const_defined?(model_name, false)

      _namespace.const_set(model_name, self)
      class_eval(&block)
      reset_column_information
    end
    @model
  end

  def define_viewmodel(&block)
    vm_name = viewmodel_name
    _namespace = namespace
    @viewmodel = Class.new(@viewmodel_base) do |c|
      raise "Viewmodel alreay defined: #{vm_name}" if _namespace.const_defined?(vm_name, false)

      _namespace.const_set(vm_name, self)
      class_eval(&block)
    end
    raise 'help help' if @viewmodel.name.nil?

    @viewmodel
  end

  def no_viewmodel
    @no_viewmodel = true
  end
end
