ActiveRecord::Base.establish_connection adapter: "sqlite3", database: ":memory:"

ActiveRecord::Schema.define do
  self.verbose = false
  create_table :parents do |t|
    t.string :name
  end

  create_table :children do |t|
    t.references :parent
    t.string :name
  end
end

class Child < ActiveRecord::Base
  belongs_to :parent
end

class Parent < ActiveRecord::Base
  has_many :children, dependent: :destroy
end

class ChildView < ActiveRecordViewModel
  table :child
  attributes :name
end

class ParentView < ActiveRecordViewModel
  table :parent
  attributes :name
  association :children
end
