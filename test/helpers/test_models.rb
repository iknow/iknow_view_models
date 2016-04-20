require "cerego_view_models"
require "active_record_view_model"
require "active_record_view_model/controller"

require "acts_as_manual_list"

require "logger"

db = :pg

case db
when :sqlite
  ActiveRecord::Base.establish_connection adapter: "sqlite3", database: ":memory:"
when :pg
  ActiveRecord::Base.establish_connection adapter: "postgresql", database: "cerego_view_models"
  %w[labels parents children targets poly_ones poly_twos owners
     grand_parents categories tags parents_tags].each do |t|
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{t} CASCADE")
  end
end

# Set up transactional tests
class ActiveSupport::TestCase
  include ActiveRecord::TestFixtures
end

ActiveRecord::Schema.define do
  self.verbose = false

  create_table :categories do |t|
    t.string :name
  end

  create_table :tags do |t|
    t.string :name
  end

  create_table :labels do |t|
    t.string :text
  end

  create_table :grand_parents do |t|
  end

  create_table :parents do |t|
    t.string :name
    t.references :label, foreign_key: true
    t.string :poly_type
    t.integer :poly_id
    t.references :grand_parent, foreign_key: true

    t.references :category, foreign_key: true # shared reference
  end

  create_table :parents_tags do |t|
    t.references :parent, foreign_key: true
    t.references :tags,   foreign_key: true
    # TODO data on join table?
  end

  create_table :owners do |t|
    t.integer :deleted_id
    t.integer :ignored_id
  end
  add_foreign_key :owners, :labels, column: :deleted_id
  add_foreign_key :owners, :labels, column: :ignored_id

  create_table :children do |t|
    t.references :parent, null: false, foreign_key: true
    t.string :name
    t.float :position
  end

  # Add an `:age` column to `:children`. SQLite doesn't support modifying
  # constraints on tables, we have to do this on creation.
  case db
  when :sqlite, :pg
    execute <<-SQL
      ALTER TABLE children ADD COLUMN age integer CHECK(age > 21)
    SQL
  else
    raise "Unable to add column with check contstraint for db engine #{db}"
  end

  create_table :targets do |t|
    t.string :text
    t.references :parent, foreign_key: true
    t.references :label, foreign_key: true
  end

  create_table :poly_ones do |t|
    t.integer :number
  end

  create_table :poly_twos do |t|
    t.string :text
  end
end

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

class Label < ApplicationRecord
  has_one :parent
  has_one :target
end

class Child < ApplicationRecord
  belongs_to :parent, inverse_of: :children
  acts_as_manual_list scope: :parent
  validates :age, numericality: {less_than: 42}, allow_nil: true
end

class Target < ApplicationRecord
  belongs_to :parent, inverse_of: :target
  belongs_to :label, dependent: :destroy
end

class PolyOne < ApplicationRecord
  has_one :parent, as: :poly
end

class PolyTwo < ApplicationRecord
  has_one :parent, as: :poly
end

class Parent < ApplicationRecord
  has_many   :children, dependent: :destroy, inverse_of: :parent
  belongs_to :label,    dependent: :destroy
  has_one    :target,   dependent: :destroy, inverse_of: :parent

  belongs_to :poly, polymorphic: true, dependent: :destroy, inverse_of: :parent

  belongs_to :grand_parent, inverse_of: :parents

  belongs_to :category
end

class Category < ApplicationRecord
  has_many :parents
end

class Owner < ApplicationRecord
  belongs_to :deleted, class_name: Label.name, dependent: :delete
  belongs_to :ignored, class_name: Label.name
end

class GrandParent < ApplicationRecord
  has_many :parents, inverse_of: :grand_parent
end

# Trampoline access checks back to the context so we can have a scoped record of
# all access checks in a (de)serailize operation.
module TestAccessLogging
  def visible!(view_context:)
    view_context.log_visible_check(self)
    super
  end

  def editable!(view_context:)
    view_context.log_edit_check(self)
    super
  end
end


module TrivialAccessControl
  def visible?(view_context:)
    view_context.can_view
  end

  def editable?(view_context:)
    view_context.can_edit
  end
end

module Views
  class ApplicationView < ActiveRecordViewModel
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

      def initialize(can_edit: true)
        super()
        self.can_edit = can_edit
      end
    end

    class SerializeContext < ViewModel::SerializeContext
      include ContextAccessLogging
      attr_accessor :can_view

      def initialize(can_view: true)
        super()
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

  class Label < ApplicationView
    self.model_class_name = :label
    attributes :text
  end

  class Child < ApplicationView
    attributes :name, :age
    acts_as_list :position

    include TrivialAccessControl
  end

  class Target < ApplicationView
    attributes :text
    association :label
  end

  class PolyOne < ApplicationView
    attributes :number
  end

  class PolyTwo < ApplicationView
    attributes :text
  end

  class Category < ApplicationView
    attributes :name
  end

  class Parent < ApplicationView
    attributes :name
    associations :children, :label, :target
    association :poly, viewmodels: [PolyOne, PolyTwo]
    association :category, shared: true

    include TrivialAccessControl
  end

  class Owner < ApplicationView
    associations :deleted, :ignored
  end

  class GrandParent < ApplicationView
    association :parents
  end
end

## Dummy Rails Controllers
class DummyController
  attr_reader :params, :status

  def initialize(**params)
    # in Rails 5, this will not be a hash, which weakens the value of the test.
    @params = params.with_indifferent_access
    @status = 200
  end

  def invoke(method)
    begin
      self.public_send(method)
    rescue Exception => ex
      handler = self.class.rescue_block(ex.class)
      case handler
      when nil
        raise
      when Symbol
        self.send(handler, ex)
      when Proc
        self.instance_exec(ex, &handler)
      end
    end
  end

  def render(status:, **options)
    if options.has_key?(:json)
      @response_body = options[:json]
      @content_type = options[:content_type] || 'application/json'
    elsif options.has_key?(:plain)
      @response_body = options[:plain]
      @content_type = options[:content_type] || 'text/plain'
    end
    @status = status unless status.nil?
  end

  def json_response
    raise "Not a JSON response" unless @content_type == 'application/json'
    @response_body
  end

  def hash_response
    JSON.parse(json_response)
  end

  class << self
    def rescue_from(type, with:)
      @rescue_blocks ||= {}
      @rescue_blocks[type] = with
    end

    def rescue_block(type)
      @rescue_blocks.try { |bs| bs.to_a.reverse.detect { |btype, h| type <= btype }.last }
    end
  end
end

# Provide dummy Rails env
class Rails
  def self.env
    'production'
  end
end

class ParentController < DummyController
  include ActiveRecordViewModel::Controller
end

class ChildController < DummyController
  include ActiveRecordViewModel::Controller
  nested_in :parent, as: :children
end
