class ViewModel::TestHelpers::ARVMBuilder
  attr_reader :name, :model, :viewmodel

  def initialize(name, model_base: ApplicationRecord, viewmodel_base: ViewModelBase, &block)
    @model_base = model_base
    @viewmodel_base = viewmodel_base
    @name = name.to_s.camelize
    @no_viewmodel = false
    instance_eval(&block)
    raise "Model not created in ARVMBuilder"     unless model
    raise "Schema not created in ARVMBuilder"    unless model.table_exists?
    raise "ViewModel not created in ARVMBuilder" unless (viewmodel || @no_viewmodel)

    # Force the realization of the view model into the library's lookup
    # table. If this doesn't happen the library may have conflicting entries in
    # the deferred table, and will allow viewmodels to leak between tests.
    ViewModel::Registry.for_view_name(viewmodel.view_name) unless @no_viewmodel
  end

  def teardown
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{name.underscore.pluralize} CASCADE")
    Object.send(:remove_const, name)
    Object.send(:remove_const, viewmodel_name) if viewmodel
    # prevent cached old class from being used to resolve associations
    ActiveSupport::Dependencies::Reference.clear!
  end

  private

  def viewmodel_name
    self.name + "View"
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
    @model = Class.new(@model_base) do |c|
      raise "Model already defined: #{model_name}" if Object.const_defined?(model_name, false)
      Object.const_set(model_name, self)
      class_eval(&block)
      reset_column_information
    end
    @model
  end

  def define_viewmodel(&block)
    vm_name = viewmodel_name
    @viewmodel = Class.new(@viewmodel_base) do |c|
      raise "Viewmodel alreay defined: #{vm_name}" if Object.const_defined?(vm_name, false)
      Object.const_set(vm_name, self)
      class_eval(&block)
    end
    raise "help help" if @viewmodel.name.nil?
    @viewmodel
  end

  def no_viewmodel
    @no_viewmodel = true
  end
end
