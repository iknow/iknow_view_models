# -*- coding: utf-8 -*-

require "bundler/setup"
Bundler.require

require_relative "../helpers/test_models.rb"

require "minitest/autorun"
require 'minitest/unit'

require "byebug"




class ActiveRecordViewModelTest < ActiveSupport::TestCase

  def setup
    @parent1 = Parent.new(name:     "p1",
                          children: [Child.new(name: "p1c1"), Child.new(name: "p1c2"), Child.new(name: "p1c3")],
                          label:    Label.new(text: "p1l"),
                          target:   Target.new(text: "p1t"),
                          poly:     PolyOne.new(number: 1))
    @parent1.save!

    @parent2 = Parent.new(name: "p2",
                          children: [Child.new(name: "p2c1"), Child.new(name: "p2c2")])
    @parent2.save!
  end

  def test_find
    parentview = ParentView.find(@parent1.id)
    assert_equal(@parent1, parentview.model)

    child = @parent1.children.first
    childview = parentview.find_associated(:children, child.id)
    assert_equal(child, childview.model)
  end

  def test_load
    parentviews = ParentView.load
    assert_equal(2, parentviews.size)

    h = parentviews.index_by(&:id)
    assert_equal(@parent1, h[@parent1.id].model)
    assert_equal(@parent2, h[@parent2.id].model)
  end

  def test_visibility
    parentview = ParentView.new(@parent1)

    assert_raises(ViewModel::SerializationError) do
      parentview.to_hash(can_view: false)
    end
  end

  def test_editability
    assert_raises(ViewModel::DeserializationError) do
      # create
      ParentView.deserialize_from_view({ "name" => "p" }, can_edit: false)
    end

    assert_raises(ViewModel::DeserializationError) do
      # edit
      v = ParentView.new(@parent1).to_hash.merge("name" => "p2")
      ParentView.deserialize_from_view(v, can_edit: false)
    end

    assert_raises(ViewModel::DeserializationError) do
      # destroy
      ParentView.new(@parent1).destroy!(can_edit: false)
    end

    assert_raises(ViewModel::DeserializationError) do
      # append child
      ParentView.new(@parent1).deserialize_associated(:children, {"text" => "hi"}, can_edit: false)
    end

    assert_raises(ViewModel::DeserializationError) do
      # replace children
      ParentView.new(@parent1).deserialize_associated(:children, [{"text" => "hi"}], can_edit: false)
    end

    assert_raises(ViewModel::DeserializationError) do
      # destroy child
      ParentView.new(@parent1).delete_associated(:target, TargetView.new(@parent1.target), can_edit: false)
    end
  end

  def test_serialize_view
    s = ParentView.new(@parent1)
    assert_equal(s.to_hash,
                 { "id"       => @parent1.id,
                   "name"     => @parent1.name,
                   "label"    => { "id" => @parent1.label.id, "text" => @parent1.label.text },
                   "target"   => { "id" => @parent1.target.id, "text" => @parent1.target.text, "label" => nil },
                   "poly_type" => @parent1.poly_type,
                   "poly"      => { "id" => @parent1.poly.id, "number" => @parent1.poly.number },
                   "children" => @parent1.children.map{|child| {"id" => child.id, "name" => child.name, "position" => child.position }}})
  end

  def test_eager_includes
    p = ParentView.eager_includes
    assert_equal({:children=>{}, :label=>{}, :target=>{:label=>{}}, :poly=>nil}, p)
  end

  def test_create_from_view
    view = {
      "name" => "p",
      "label" => { "text" => "l" },
      "target" => { "text" => "t" },
      "children" => [{ "name" => "c1" }, {"name" => "c2"}],
      "poly_type" => "PolyTwo",
      "poly" => { "text" => "pol" }
    }

    pv = ParentView.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal("p", p.name)

    assert(p.label.present?)
    assert_equal("l", p.label.text)

    assert(p.target.present?)
    assert_equal("t", p.target.text)

    assert_equal(2, p.children.count)
    p.children.order(:id).each_with_index do |c, i|
      assert(!c.changed?)
      assert(!c.new_record?)
      assert_equal("c#{i + 1}", c.name)
    end

    assert(p.poly.present?)
    assert(p.poly.is_a?(PolyTwo))
    assert_equal("pol", p.poly.text)
  end

  def test_bad_single_association
    view = {
      "children" => nil
    }
    assert_raises(ViewModel::DeserializationError) do
      ParentView.deserialize_from_view(view)
    end
  end

  def test_bad_multiple_association
    view = {
      "target" => []
    }
    assert_raises(ViewModel::DeserializationError) do
      ParentView.deserialize_from_view(view)
    end
  end

  def test_create_without_polymorphic_type
   view = {
      "name" => "p",
      "poly" => { "text" => "pol" }
    }

    assert_raises(ViewModel::DeserializationError) do
     ParentView.deserialize_from_view(view)
    end
  end

  def test_edit_attribute_from_view
    view = ParentView.new(@parent1).to_hash

    view["name"] = "renamed"
    ParentView.deserialize_from_view(view)

    @parent1.reload
    assert_equal("renamed", @parent1.name)
  end

  ### Test Associations
  ### has_many

  def test_has_many_empty_association
    #create
    view = { "name" => "p", "children" => [] }
    pv = ParentView.deserialize_from_view(view)
    p = pv.model
    assert(p.children.blank?)

    # update
    h = pv.to_hash
    child = Child.new(name: "x")
    p.children << child
    p.save!

    ParentView.deserialize_from_view(h)
    p.reload
    assert(p.children.blank?)
    assert(Child.where(id: child.id).blank?)
  end

  def test_replace_has_many
    view = ParentView.new(@parent1).to_hash
    old_children = @parent1.children

    view["children"] = [{"name" => "new_child"}]
    ParentView.deserialize_from_view(view)

    @parent1.reload
    assert_equal(1, @parent1.children.size)
    old_children.each {|child| assert_not_equal(child, @parent1.children.first) }
    assert_equal("new_child", @parent1.children.first.name)
  end

  def test_edit_has_many
    old_children = @parent1.children.order(:position).to_a
    view = ParentView.new(@parent1).to_hash

    view["children"].shift
    view["children"] << { "name" => "c3" }
    ParentView.deserialize_from_view(view)

    @parent1.reload
    assert_equal(3, @parent1.children.size)
    tc1, tc2, tc3 = @parent1.children.order(:position)

    assert_equal(old_children[1], tc1)
    assert_equal(1, tc1.position)

    assert_equal(old_children[2], tc2)
    assert_equal(2, tc2.position)

    assert_equal("c3", tc3.name)
    assert_equal(3, tc3.position)

    assert(Child.where(id: old_children[0].id).blank?)
  end

  def test_edit_explicit_list_position
    old_children = @parent1.children.order(:position).to_a

    view = ParentView.new(@parent1).to_hash

    view["children"][0]["position"] = 2
    view["children"][1]["position"] = 1
    view["children"] << { "name" => "c3" }
    view["children"] << { "name" => "c4" }
    ParentView.deserialize_from_view(view)

    @parent1.reload
    assert_equal(5, @parent1.children.size)
    tc1, tc2, tc3, tc4, tc5 = @parent1.children.order(:position)
    assert_equal(old_children[1], tc1)
    assert_equal(old_children[0], tc2)
    assert_equal(old_children[2], tc3)
    assert_equal("c3", tc4.name)
    assert_equal("c4", tc5.name)
  end

  def test_edit_implicit_list_position
    old_children = @parent1.children.order(:position).to_a

    view = ParentView.new(@parent1).to_hash

    view["children"].each { |c| c.delete("position") }
    view["children"].reverse!
    view["children"].insert(1, { "name" => "c3" })

    ParentView.deserialize_from_view(view)

    @parent1.reload
    assert_equal(4, @parent1.children.size)
    tc1, tc2, tc3, tc4 = @parent1.children.order(:position)

    assert_equal(old_children[2], tc1)
    assert_equal(1, tc1.position)

    assert_equal("c3", tc2.name)
    assert_equal(2, tc2.position)

    assert_equal(old_children[1], tc3)
    assert_equal(3, tc3.position)

    assert_equal(old_children[0], tc4)
    assert_equal(4, tc4.position)
  end

  def test_build_explicit_position
    skip
  end

  def test_build_implicit_position
    skip
  end

  def test_move_child_to_new
    child = Child.new(name: "c2")
    old_parent = Parent.new(name: "old_p", children: [Child.new(name: "c1"), child, Child.new(name: "c3")])
    old_parent.save!

    child_view = ChildView.new(child).to_hash

    view = { "name" => "new_p", "children" => [child_view, {"name" => "new"}]}
    pv = ParentView.deserialize_from_view(view)
    parent = pv.model

    # child should be removed from old parent and positions updated
    old_parent.reload
    assert_equal(2, old_parent.children.size)
    oc1, oc2 = old_parent.children.order(:position)
    assert_equal("c1", oc1.name)
    assert_equal(1, oc1.position)
    assert_equal("c3", oc2.name)
    assert_equal(2, oc2.position)

    # child should be added to new parent with valid position
    assert_equal(2, parent.children.size)
    nc1, nc2 = parent.children.order(:position)
    assert_equal(child, nc1)
    assert_equal("c2", nc1.name)
    assert_equal(1, nc1.position)
    assert_equal("new", nc2.name)
    assert_equal(2, nc2.position)
  end

  def test_move_child_to_existing
    old_child = Child.new(name: "c2")
    old_parent = Parent.new(name: "old_p", children: [Child.new(name: "c0"), Child.new(name: "c1"), old_child, Child.new(name: "c3")])
    old_parent.save!

    new_child = Child.new(name: "newc")
    new_parent = Parent.new(name: "new_p", children: [new_child])
    new_parent.save!

    view = ParentView.new(new_parent).to_hash
    view["children"] << ChildView.new(old_child).to_hash

    ParentView.deserialize_from_view(view)

    # child should be removed from old parent and positions updated
    old_parent.reload
    new_parent.reload

    assert_equal(3, old_parent.children.size)
    oc1, oc2, oc3 = old_parent.children.order(:position)
    assert_equal("c0", oc1.name)
    assert_equal(1, oc1.position)
    assert_equal("c1", oc2.name)
    assert_equal(2, oc2.position)
    assert_equal("c3", oc3.name)
    assert_equal(3, oc3.position)

    # child should be added to new parent with valid position
    assert_equal(2, new_parent.children.size)
    nc1, nc2 = new_parent.children.order(:position)
    assert_equal("newc", nc1.name)
    assert_equal(1, nc1.position)
    assert_equal(old_child, nc2)
    assert_equal("c2", nc2.name)
    assert_equal(2, nc2.position)
  end

  def test_move_and_edit_child_to_new
    child = Child.new(name: "c2")
    old_parent = Parent.new(name: "old_p", children: [Child.new(name: "c1"), child, Child.new(name: "c3")])
    old_parent.save!

    child_view = ChildView.new(child).to_hash
    child_view["name"] = "changed"

    view = { "name" => "new_p", "children" => [child_view, {"name" => "new"}]}
    pv = ParentView.deserialize_from_view(view)
    parent = pv.model

    # child should be removed from old parent and positions updated
    old_parent.reload
    assert_equal(2, old_parent.children.size)
    oc1, oc2 = old_parent.children.order(:position)
    assert_equal("c1", oc1.name)
    assert_equal(1, oc1.position)
    assert_equal("c3", oc2.name)
    assert_equal(2, oc2.position)

    # child should be added to new parent with valid position
    assert_equal(2, parent.children.size)
    nc1, nc2 = parent.children.order(:position)
    assert_equal(child, nc1)
    assert_equal("changed", nc1.name)
    assert_equal(1, nc1.position)
    assert_equal("new", nc2.name)
    assert_equal(2, nc2.position)
  end

  def test_move_and_edit_child_to_existing
    old_child = Child.new(name: "c2")
    old_parent = Parent.new(name: "old_p", children: [Child.new(name: "c0"), Child.new(name: "c1"), old_child, Child.new(name: "c3")])
    old_parent.save!

    new_child = Child.new(name: "newc")
    new_parent = Parent.new(name: "new_p", children: [new_child])
    new_parent.save!

    old_child_view = ChildView.new(old_child).to_hash
    old_child_view["name"] = "changed"
    view = ParentView.new(new_parent).to_hash
    view["children"] << old_child_view

    ParentView.deserialize_from_view(view)

    # child should be removed from old parent and positions updated
    old_parent.reload
    new_parent.reload

    assert_equal(3, old_parent.children.size)
    oc1, oc2, oc3 = old_parent.children.order(:position)

    assert_equal("c0", oc1.name)
    assert_equal(1, oc1.position)
    assert_equal("c1", oc2.name)
    assert_equal(2, oc2.position)
    assert_equal("c3", oc3.name)
    assert_equal(3, oc3.position)

    # child should be added to new parent with valid position
    assert_equal(2, new_parent.children.size)
    nc1, nc2 = new_parent.children.order(:position)
    assert_equal("newc", nc1.name)
    assert_equal(1, nc1.position)
    assert_equal(old_child, nc2)
    assert_equal("changed", nc2.name)
    assert_equal(2, nc2.position)
  end

  ### belongs_to

  def test_belongs_to_nil_association
    # create
    view = { "name" => "p", "label" => nil }
    pv = ParentView.deserialize_from_view(view)
    p = pv.model
    assert_nil(p.label)

    # update
    h = pv.to_hash
    p.label = label = Label.new(text: "hello")
    p.save!

    ParentView.deserialize_from_view(h)
    p.reload
    assert_nil(p.label)
    assert(Label.where(id: label.id).blank?)
  end

  def test_belongs_to_create
    p = Parent.create(name: "p")

    view = ParentView.new(p).to_hash
    view["label"] = { "text" => "cheese" }

    ParentView.deserialize_from_view(view)
    p.reload

    assert(p.label.present?)
    assert_equal("cheese", p.label.text)
  end

  def test_belongs_to_move_and_replace
    l1 = Label.new(text: "l1")
    p1 = Parent.new(name: "p1", label: l1)
    p1.save!

    l2 = Label.new(text: "l2")
    p2 = Parent.new(name: "p2", label: l2)
    p2.save!

    v1 = ParentView.new(p1).to_hash
    v2 = ParentView.new(p2).to_hash

    # move l1 to p2
    # l2 should be garbage collected
    # p1 should now have no label

    v2["label"] = v1["label"]

    ParentView.deserialize_from_view(v2)

    p1.reload
    p2.reload

    assert(p1.label.blank?)
    assert(p2.label.present?)
    assert_equal("l1", p2.label.text)
  end

  def test_belongs_to_build_new_association
    l = Label.new(text: "l1")
    p = Parent.new(name: "p1", label: l)
    p.save!

    ParentView.new(p).deserialize_associated(:label, { "text" => "l2" })

    p.reload

    assert(Label.where(id: l.id).blank?)
    assert_equal("l2", p.label.text)
  end

  def test_belongs_to_update_existing_association
    l = Label.new(text: "l1")
    p = Parent.new(name: "p1", label: l)
    p.save!

    lv = LabelView.new(l).to_hash
    lv["text"] = "l2"

    ParentView.new(p).deserialize_associated(:label, lv)

    p.reload

    assert_equal(l, p.label)
    assert_equal("l2", p.label.text)
  end

  def test_belongs_to_move_existing_association
    l1 = Label.new(text: "l1")
    p1 = Parent.new(name: "p1", label: l1)
    p1.save!

    l2 = Label.new(text: "l2")
    p2 = Parent.new(name: "p2", label: l2)
    p2.save!

    ParentView.new(p2).deserialize_associated("label", { "id" => l1.id })

    p1.reload
    p2.reload

    assert(p1.label.blank?)
    assert(Label.where(id: l2.id).blank?)

    assert_equal(l1, p2.label)
    assert_equal("l1", p2.label.text)
  end

  ### has_one

  def test_has_one_nil_association
    # create
    view = { "name" => "p", "target" => nil }
    pv = ParentView.deserialize_from_view(view)
    p = pv.model
    assert_nil(p.target)

    # update
    h = pv.to_hash
    p.target = target = Target.new
    p.save!

    ParentView.deserialize_from_view(h)
    p.reload
    assert_nil(p.target)
    assert(Target.where(id: target.id).blank?)
  end

  def test_has_one_create
    p = Parent.create(name: "p")

    view = ParentView.new(p).to_hash
    view["target"] = { }

    ParentView.deserialize_from_view(view)
    p.reload

    assert(p.target.present?)
  end

  def test_has_one_move_and_replace
    t1 = Target.new(text: "t1")
    p1 = Parent.new(name: "p1", target: t1)
    p1.save!

    t2 = Target.new(text: "t2")
    p2 = Parent.new(name: "p2", target: t2)
    p2.save!

    v1 = ParentView.new(p1).to_hash
    v2 = ParentView.new(p2).to_hash

    v2["target"] = v1["target"]

    ParentView.deserialize_from_view(v2)
    p1.reload
    p2.reload

    assert(p1.target.blank?)
    assert(p2.target.present?)
    assert_equal(t1.text, p2.target.text)

    assert(Target.where(id: t2).blank?)
  end

  def test_has_one_build_new_association
    t = Target.new(text: "t1")
    p = Parent.new(name: "p1", target: t)
    p.save!

    ParentView.new(p).deserialize_associated(:target, { "text" => "t2" })

    p.reload

    assert(Target.where(id: t.id).blank?)
    assert_equal("t2", p.target.text)
  end

  def test_has_one_update_existing_association
    t = Target.new(text: "t1")
    p = Parent.new(name: "p1", target: t)
    p.save!

    tv = TargetView.new(t).to_hash
    tv["text"] = "t2"

    ParentView.new(p).deserialize_associated(:target, tv)

    p.reload

    assert_equal(t, p.target)
    assert_equal("t2", p.target.text)
  end

  def test_has_one_move_existing_association
    t1 = Target.new(text: "t1")
    p1 = Parent.new(name: "p1", target: t1)
    p1.save!

    t2 = Target.new(text: "t2")
    p2 = Parent.new(name: "p2", target: t2)
    p2.save!

    ParentView.new(p2).deserialize_associated("target", { "id" => t1.id })

    p1.reload
    p2.reload

    assert(p1.target.blank?)
    assert(Target.where(id: t2.id).blank?)

    assert_equal(t1, p2.target)
    assert_equal("t1", p2.target.text)
  end


  # test other dependent: delete_all
  def test_dependent_delete_all
    skip
  end

  def test_dependent_ignore
    skip
  end

  # test building extra child in association
  def test_has_many_build_new_association
    child = Child.new(name: "c1")
    parent = Parent.new(name: "p", children: [child])
    parent.save!

    ParentView.new(parent).deserialize_associated(:children, { "name" => "c2" })

    parent.reload

    assert_equal(2, parent.children.size)
    c1, c2 = parent.children.order(:position)
    assert_equal(child, c1)
    assert_equal("c2", c2.name)
  end

  def test_has_many_update_existing_association
    child = Child.new(name: "c1")
    parent = Parent.new(name: "p", children: [child])
    parent.save!

    cv = ChildView.new(child).to_hash
    cv["name"] = "c2"

    ParentView.new(parent).deserialize_associated(:children, cv)

    parent.reload

    assert_equal(1, parent.children.size)
    assert_equal(child, parent.children.first)
    assert_equal("c2", parent.children.first.name)
  end

  def test_has_many_move_existing_association
    c1 = Child.new(name: "c1")
    p1 = Parent.new(name: "p1", children: [c1])
    p1.save!

    c2 = Child.new(name: "c2")
    p2 = Parent.new(name: "p2", children: [c2])
    p2.save!


    ParentView.new(p2).deserialize_associated("children", { "id" => c1.id })

    p1.reload
    p2.reload

    assert_equal(0, p1.children.size)

    assert_equal(2, p2.children.size)
    p1c1, p1c2 = p2.children.order(:position)
    assert_equal(c2, p1c1)
    assert_equal(c1, p1c2)
  end

  def test_delete_association
    c1 = Child.new(name: "c1")
    c2 = Child.new(name: "c2")
    p1 = Parent.new(name: "p1", children: [c1, c2])
    p1.save!

    ParentView.new(p1).delete_associated("children", ChildView.new(c1))
    p1.reload

    assert_equal(1, p1.children.size)
    assert_equal(c2, p1.children.first)
    assert_equal(1, p1.children.first.position)

    assert(Child.where(id: c1).blank?)
  end
end
