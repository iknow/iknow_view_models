# -*- coding: utf-8 -*-

require "bundler/setup"
Bundler.require

require "minitest/autorun"
require "byebug"

require_relative "../helpers/test_models.rb"

class ActiveRecordViewModelTest < ActiveSupport::TestCase

  def test_serialize_view
    child = Child.new(name: "c1")
    parent = Parent.new(name: "p", children: [child])
    parent.save!

    s = ParentView.new(parent)
    assert_equal(ViewModel.serialize_to_hash(s),
                 { "id" => parent.id,
                   "name" => parent.name,
                   "children" => [{"id" => child.id, "name" => child.name }]})
  end


  def test_create_from_view
    view = { "name" => "p", "children" => [{ "name" => "c1" }, {"name" => "c2"}]}

    pv = ParentView.create_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)
    assert_equal("p", p.name)
    assert_equal(2, p.children.count)
    p.children.order(:id).each_with_index do |c, i|
      assert(!c.changed?)
      assert(!c.new_record?)
      assert_equal("c#{i + 1}", c.name)
    end
  end
end
