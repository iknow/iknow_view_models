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
    t.references :parent
    t.string :name
    t.integer :position
  end

  create_table :labels do |t|
    t.string :text
  end

  create_table :targets do |t|
    t.string :text
    t.references :parent
  end
end

class Label < ActiveRecord::Base
  has_one :parent
end

class Child < ActiveRecord::Base
  belongs_to :parent
  acts_as_list scope: :parent
end

class Target < ActiveRecord::Base
  belongs_to :parent
end

class Parent < ActiveRecord::Base
  has_many   :children, dependent: :destroy
  belongs_to :label,    dependent: :destroy
  has_one    :target,   dependent: :destroy
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
