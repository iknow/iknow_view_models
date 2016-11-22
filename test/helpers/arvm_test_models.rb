require "iknow_view_models"
require "view_model/active_record"
require "view_model/active_record/controller"

require "acts_as_manual_list"

db_config_path = File.join(File.dirname(__FILE__), '../config/database.yml')
db_config = YAML.load(File.open(db_config_path))
raise "Test database configuration missing" unless db_config["test"]
ActiveRecord::Base.establish_connection(db_config["test"])

# Remove test tables if any exist
%w[labels parents children targets poly_ones poly_twos owners
     grand_parents categories tags parents_tags].each do |t|
  ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{t} CASCADE")
end

# Set up transactional tests
class ActiveSupport::TestCase
  include ActiveRecord::TestFixtures
end

# Base class for models
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

# base class for viewmodels
class ViewModelBase < ViewModel::ActiveRecord
  self.abstract_class = true

  module ContextAccessLogging
    attr_accessor :edit_checks, :visible_checks

    def initialize(**args)
      super

      # force existence of these objects, so when we get cloned in context we
      # get aliased.
      @edit_checks    = []
      @visible_checks = []
    end

    def log_edit_check(viewmodel)
      edit_checks << viewmodel.to_reference
    end

    def log_visible_check(viewmodel)
      visible_checks << viewmodel.to_reference
    end
  end

  class DeserializeContext < ViewModel::DeserializeContext
    include ContextAccessLogging
    attr_accessor :can_edit
    attr_accessor :can_view

    def initialize(can_edit: true, can_view: true, **rest)
      super(**rest)
      self.can_edit = can_edit
      self.can_view = can_view
    end
  end

  class SerializeContext < ViewModel::SerializeContext
    include ContextAccessLogging
    attr_accessor :can_view

    def initialize(can_view: true, **rest)
      super(**rest)
      self.can_view = can_view
    end
  end

  # TODO abstract class like active record

  def self.deserialize_context_class
    DeserializeContext
  end

  def self.serialize_context_class
    SerializeContext
  end

  def visible?(context:)
    context.log_visible_check(self)
    super && context.can_view
  end

  def editable?(deserialize_context:, changed_associations:, deleted:)
    deserialize_context.log_edit_check(self)
    super && deserialize_context.can_edit
  end

end

class ARVMBuilder
  attr_reader :name, :model, :viewmodel

  def initialize(name, &block)
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
    @model = Class.new(ApplicationRecord) do |c|
      raise "Model already defined: #{model_name}" if Object.const_defined?(model_name, false)
      Object.const_set(model_name, self)
      class_eval(&block)
      reset_column_information
    end
    @model
  end

  def define_viewmodel(&block)
    vm_name = viewmodel_name
    @viewmodel = Class.new(ViewModelBase) do |c|
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
