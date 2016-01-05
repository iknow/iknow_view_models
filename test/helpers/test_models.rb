require "acts_as_list"

require "logger"
ActiveRecord::Base.logger = Logger.new(STDOUT)

ActiveRecord::Base.establish_connection adapter: "sqlite3", database: ":memory:"

ActiveRecord::Schema.define do
  self.verbose = false
  create_table :parents do |t|
    t.string :name
    t.references :label
  end

  create_table :children do |t|
    t.references :parent, null: false
    t.string :name
    t.integer :position
  end

  create_table :labels do |t|
    t.string :text
  end

  create_table :targets do |t|
    t.string :text
    t.references :parent, null: false
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
