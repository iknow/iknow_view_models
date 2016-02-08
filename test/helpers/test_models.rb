require "acts_as_list"

require "logger"
ActiveRecord::Base.logger = Logger.new(STDOUT)

db = :sqlite

case db
when :sqlite
  ActiveRecord::Base.establish_connection adapter: "sqlite3", database: ":memory:"
when :pg
  ActiveRecord::Base.establish_connection adapter: "postgresql", database: "candreae"
  %w[labels parents children targets poly_ones poly_twos owners].each do |t|
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{t} CASCADE")
  end
end

# Set up transactional tests
class ActiveSupport::TestCase
  include ActiveRecord::TestFixtures
end

ActiveRecord::Schema.define do
  self.verbose = false
  create_table :labels do |t|
    t.string :text
  end

  create_table :parents do |t|
    t.string :name
    t.references :label, foreign_key: true
    t.string :poly_type
    t.integer :poly_id
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
    t.integer :position
  end

  create_table :targets do |t|
    t.string :text
    t.references :parent, null: false, foreign_key: true
    t.references :label, foreign_key: true
  end

  create_table :poly_ones do |t|
    t.integer :number
  end

  create_table :poly_twos do |t|
    t.string :text
  end
end

class Label < ActiveRecord::Base
  has_one :parent
  has_one :target
end

class Child < ActiveRecord::Base
  belongs_to :parent, inverse_of: :children
  acts_as_list scope: :parent
end

class Target < ActiveRecord::Base
  belongs_to :parent, inverse_of: :target
  belongs_to :label, dependent: :destroy
end

class PolyOne < ActiveRecord::Base
  has_one :parent, as: :poly
end

class PolyTwo < ActiveRecord::Base
  has_one :parent, as: :poly
end

class Parent < ActiveRecord::Base
  has_many   :children, dependent: :destroy, inverse_of: :parent
  belongs_to :label,    dependent: :destroy
  has_one    :target,   dependent: :destroy, inverse_of: :parent
  belongs_to :poly, polymorphic: true, dependent: :destroy, inverse_of: :parent
end

class Owner < ActiveRecord::Base
  belongs_to :deleted, class_name: Label.name, dependent: :delete
  belongs_to :ignored, class_name: Label.name
end

module TrivialAccessControl
  def visible?(can_view: true)
    can_view
  end

  def editable?(can_edit: true)
    can_edit
  end
end

class LabelView < ActiveRecordViewModel
  self.model_class_name = :label
  attributes :text
end

class ChildView < ActiveRecordViewModel
  attributes :name, :position
  acts_as_list :position

  include TrivialAccessControl
end

class TargetView < ActiveRecordViewModel
  attributes :text
  association :label
end

class ParentView < ActiveRecordViewModel
  attributes :name, :poly_type
  associations :children, :label, :target, :poly

  include TrivialAccessControl
end

class PolyOneView < ActiveRecordViewModel
  attributes :number
end

class PolyTwoView < ActiveRecordViewModel
  attributes :text
end

class OwnerView < ActiveRecordViewModel
  associations :deleted, :ignored
end


## Dummy Rails Controllers
class DummyController
  attr_reader :params, :json_response, :status

  def initialize(**params)
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

  def render(json:, status:)
    @json_response = json
    @status = status unless status.nil?
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

  def initialize(**args)
    super
  end
end

class ChildController < DummyController
  include ActiveRecordViewModel::Controller
  nested_in :parent, as: :children

  def initialize(**args)
    super
  end
end
