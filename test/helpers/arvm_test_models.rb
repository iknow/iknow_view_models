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

# Trampoline access checks back to the context so we can have a scoped record of
# all access checks in a (de)serailize operation.
module TestAccessLogging
  def visible!(context:)
    context.log_visible_check(self)
    super
  end

  def editable!(deserialize_context:)
    deserialize_context.log_edit_check(self)
    super
  end
end


module TrivialAccessControl
  def visible?(context:)
    context.can_view
  end

  def editable?(deserialize_context:)
    deserialize_context.can_edit
  end
end

# base class for viewmodels
class ViewModelBase < ViewModel::ActiveRecord
  self.abstract_class = true

  module ContextAccessLogging
    def edit_checks
      # Create is expressed as edit checking a new model. Since checks are
      # recorded as (viewmodel_class, model_class, id), and we want to verify
      # multiple creation events, we record everything here and sort it as
      # appropriate.
      @edit_checks ||= []
    end

    def log_edit_check(viewmodel)
      edit_checks << [viewmodel.class, viewmodel.model.id]
    end

    # def visible_checks
    #   @visible_checks ||= []
    # end

    def log_visible_check(viewmodel)
      # TODO format not specified yet
      # visible_checks << [viewmodel.class, viewmodel.model.id]
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

  include TestAccessLogging

  def self.deserialize_context_class
    DeserializeContext
  end

  def self.serialize_context_class
    SerializeContext
  end
end

class ARVMBuilder
  attr_reader :name, :model, :viewmodel

  def initialize(name, &block)
    @name = name.to_s.camelize
    instance_eval(&block)
    raise "Model not created in ARVMBuilder"     unless model
    raise "Schema not created in ARVMBuilder"    unless model.table_exists?
    raise "ViewModel not created in ARVMBuilder" unless (viewmodel || @no_viewmodel)
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
