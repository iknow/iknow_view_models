require_relative "test_access_control.rb"

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

  class DeserializeContext < ViewModel::DeserializeContext
    def initialize(can_view: true, can_edit: true, can_change: true, **params)
      params[:access_control] ||= TestAccessControl.new(can_view, can_edit, can_change)
      super(**params)
    end

    delegate :visible_checks, :editable_checks, :valid_edit_refs, :valid_edit_changes, :all_valid_edit_changes, :was_edited?, to: :access_control
  end

  def self.deserialize_context_class
    DeserializeContext
  end

  class SerializeContext < ViewModel::SerializeContext
    def initialize(can_view: true, **params)
      params[:access_control] ||= TestAccessControl.new(can_view, false, false)
      super(**params)
    end

    delegate :visible_checks, :editable_checks, :valid_edit_refs, :valid_edit_changes, :all_valid_edit_changes, to: :access_control
  end

  def self.serialize_context_class
    SerializeContext
  end
end
