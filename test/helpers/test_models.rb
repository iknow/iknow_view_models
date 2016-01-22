require "acts_as_list"

require "logger"
ActiveRecord::Base.logger = Logger.new(STDOUT)

db = :sqlite

case db
when :sqlite
  ActiveRecord::Base.establish_connection adapter: "sqlite3", database: ":memory:"
when :pg
  ActiveRecord::Base.establish_connection adapter: "postgresql", database: "candreae"
  %w[labels parents children targets poly_ones poly_twos].each do |t|
    ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS #{t} CASCADE")
  end
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
