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

  class TestAccessControl < ViewModel::AccessControl
    attr_accessor :editable_checks, :visible_checks, :valid_edit_checks

    def initialize(can_view, can_edit, can_change)
      super()
      @can_edit           = can_edit
      @can_view           = can_view
      @can_change         = can_change
      @editable_checks    = []
      @valid_edit_checks  = []
      @visible_checks     = []
      @valid_edit_changes = {}
    end

    def editable_check(view, deserialize_context:)
      @editable_checks << view.to_reference
      ViewModel::AccessControl::Result.new(@can_edit)
    end

    def valid_edit_check(view, deserialize_context:, changes:)
      ref = view.to_reference
      @valid_edit_checks << ref
      @valid_edit_changes[ref] = changes
      ViewModel::AccessControl::Result.new(@can_change)
    end

    def visible_check(view, context:)
      @visible_checks << view.to_reference
      ViewModel::AccessControl::Result.new(@can_view)
    end

    def valid_edit_changes(ref)
      @valid_edit_changes[ref]
    end
  end

  class DeserializeContext < ViewModel::DeserializeContext
    def initialize(can_view: true, can_edit: true, can_change: true, **params)
      params[:access_control] ||= TestAccessControl.new(can_view, can_edit, can_change)
      super(**params)
    end

    delegate :visible_checks, :valid_edit_checks, :editable_checks, :valid_edit_changes, to: :access_control
  end

  def self.deserialize_context_class
    DeserializeContext
  end

  class SerializeContext < ViewModel::SerializeContext
    def initialize(can_view: true, **params)
      params[:access_control] ||= TestAccessControl.new(can_view, false, false)
      super(**params)
    end

    delegate :visible_checks, :valid_edit_checks, :editable_checks, to: :access_control
  end

  def self.serialize_context_class
    SerializeContext
  end
end
