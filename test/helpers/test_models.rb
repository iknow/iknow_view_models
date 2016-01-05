require "acts_as_list"

require "logger"
ActiveRecord::Base.logger = Logger.new(STDOUT)

db = :sqlite

case db
when :sqlite
  ActiveRecord::Base.establish_connection adapter: "sqlite3", database: ":memory:"
when :pg
  ActiveRecord::Base.establish_connection adapter: "postgresql", database: "candreae"
  %w[labels parents children targets].each do |t|
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
  end

  create_table :children do |t|
    t.references :parent, null: false, foreign_key: true
    t.string :name
    t.integer :position
  end

  create_table :targets do |t|
    t.string :text
    t.references :parent, null: false, foreign_key: true
  end
end

class Label < ActiveRecord::Base
  has_one :parent, inverse_of: :label
end

class Child < ActiveRecord::Base
  belongs_to :parent, inverse_of: :children
  acts_as_list scope: :parent
end

class Target < ActiveRecord::Base
  belongs_to :parent, inverse_of: :target
end

class Parent < ActiveRecord::Base
  has_many   :children, dependent: :destroy, inverse_of: :parent
  belongs_to :label,    dependent: :destroy, inverse_of: :parent
  has_one    :target,   dependent: :destroy, inverse_of: :parent
end

class LabelView < ActiveRecordViewModel
  table :label
  attributes :text
end

class ChildView < ActiveRecordViewModel
  table :child
  attributes :name
  acts_as_list :position
end

class TargetView < ActiveRecordViewModel
  table :target
  attributes :text
end

class ParentView < ActiveRecordViewModel
  table :parent
  attributes :name
  associations :children, :label, :target
end
