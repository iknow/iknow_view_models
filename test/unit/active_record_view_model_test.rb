# -*- coding: utf-8 -*-

require "bundler/setup"
Bundler.require

require "minitest/autorun"
require "byebug"

require_relative "../helpers/test_models.rb"

class ActiveRecordViewModelTest < ActiveSupport::TestCase

  def test_serialize_view
    child = Child.new(name: "c1")
    label = Label.new(text: "hello")
    target = Target.new(text: "goodbye")
    parent = Parent.new(name: "p", children: [child], label: label, target: target)
    parent.save!

    s = ParentView.new(parent)
    assert_equal(s.to_hash,
                 { "id" => parent.id,
                   "name" => parent.name,
                   "label" => { "id" => label.id, "text" => label.text },
                   "target" => { "id" => target.id, "text" => target.text },
                   "children" => [{"id" => child.id, "name" => child.name, "position" => 1 }]})
  end

  def test_create_from_view
    view = { "name" => "p", "label" => { "text" => "l" }, "children" => [{ "name" => "c1" }, {"name" => "c2"}]}

    pv = ParentView.create_or_update_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)
    assert_equal("p", p.name)
    assert(p.label.present?)
    assert_equal("l", p.label.text)
    assert_equal(2, p.children.count)
    p.children.order(:id).each_with_index do |c, i|
      assert(!c.changed?)
      assert(!c.new_record?)
      assert_equal("c#{i + 1}", c.name)
    end
  end

  def test_edit_attribute_from_view
    child = Child.new(name: "c1")
    parent = Parent.new(name: "p", children: [child])
    parent.save!

    view = ParentView.new(parent).to_hash

    view["name"] = "p2"
    ParentView.create_or_update_from_view(view)

    parent.reload
    assert_equal("p2", parent.name)
    assert_equal([child], parent.children)
  end

  ### Associations

  ### has_many

  def test_has_many_empty_association
    #create
    view = { "name" => "p", "children" => [] }
    pv = ParentView.create_or_update_from_view(view)
    p = pv.model
    assert(p.children.blank?)

    # update
    h = pv.to_hash
    child = Child.new(name: "x")
    p.children << child
    p.save!

    ParentView.create_or_update_from_view(h)
    p.reload
    assert(p.children.blank?)
    assert(Child.where(id: child.id).blank?)
  end

  def test_replace_has_many
    child = Child.new(name: "c1")
    parent = Parent.new(name: "p", children: [child])
    parent.save!

    view = ParentView.new(parent).to_hash

    view["children"] = [{name: "c2"}]
    ParentView.create_or_update_from_view(view)

    parent.reload
    assert_equal(1, parent.children.size)
    assert_not_equal(child, parent.children.first)
    assert_equal("c2", parent.children.first.name)
  end

  def test_edit_has_many
    child1 = Child.new(name: "c1")
    child2 = Child.new(name: "c2")
    parent = Parent.new(name: "p", children: [child1, child2])
    parent.save!

    view = ParentView.new(parent).to_hash

    view["children"].shift
    view["children"] << { name: "c3" }
    ParentView.create_or_update_from_view(view)

    parent.reload
    assert_equal(2, parent.children.size)
    tc1, tc2 = parent.children.order(:position)

    assert_equal(child2, tc1)
    assert_equal(1, tc1.position)

    assert_equal("c3", tc2.name)
    assert_equal(2, tc2.position)

    assert(Child.where(id: child1.id).blank?)
  end

  def test_edit_has_many_reversed
    skip "Haven't implemented reverse side of acts_as_list assignment."

    child1 = Child.new(name: "c1")
    child2 = Child.new(name: "c2")
    parent = Parent.new(name: "p", children: [child1, child2])
    parent.save!

    view = ParentView.new(parent).to_hash

    view["children"].shift
    view["children"].unshift({ name: "c3" })
    ParentView.create_or_update_from_view(view)

    parent.reload
    assert_equal(2, parent.children.size)
    tc1, tc2 = parent.children.order(:position)

    assert_equal("c3", tc1.name)
    assert_equal(1, tc1.position)

    assert_equal(child2, tc2)
    assert_equal(2, tc2.position)
  end

  def test_move_child_to_new
    child = Child.new(name: "c2")
    old_parent = Parent.new(name: "old_p", children: [Child.new(name: "c1"), child, Child.new(name: "c3")])
    old_parent.save!

    child_view = ChildView.new(child).to_hash

    view = { "name" => "new_p", "children" => [child_view, {"name" => "new"}]}
    pv = ParentView.create_or_update_from_view(view)
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

    ParentView.create_or_update_from_view(view)

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
    pv = ParentView.create_or_update_from_view(view)
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

    ParentView.create_or_update_from_view(view)

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
    pv = ParentView.create_or_update_from_view(view)
    p = pv.model
    assert_nil(p.label)

    # update
    h = pv.to_hash
    p.label = label = Label.new(text: "hello")
    p.save!

    ParentView.create_or_update_from_view(h)
    p.reload
    assert_nil(p.label)
    assert(Label.where(id: label.id).blank?)
  end

  def test_belongs_to_create
    p = Parent.create(name: "p")

    view = ParentView.new(p).to_hash
    view["label"] = { "text" => "cheese" }

    pv = ParentView.create_or_update_from_view(view)
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

    v2["label"] = v1["label"]

    ParentView.create_or_update_from_view(v2)
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

    ParentView.new(p).create_or_update_associated(:label, { "text" => "l2" })

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

    ParentView.new(p).create_or_update_associated(:label, lv)

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

    ParentView.new(p2).create_or_update_associated("label", { "id" => l1.id })

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
    pv = ParentView.create_or_update_from_view(view)
    p = pv.model
    assert_nil(p.target)

    # update
    h = pv.to_hash
    p.target = target = Target.new
    p.save!

    ParentView.create_or_update_from_view(h)
    p.reload
    assert_nil(p.target)
    assert(Target.where(id: target.id).blank?)
  end

  def test_has_one_create
    p = Parent.create(name: "p")

    view = ParentView.new(p).to_hash
    view["target"] = { }

    pv = ParentView.create_or_update_from_view(view)
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

    ParentView.create_or_update_from_view(v2)
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

    ParentView.new(p).create_or_update_associated(:target, { "text" => "t2" })

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

    ParentView.new(p).create_or_update_associated(:target, tv)

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

    ParentView.new(p2).create_or_update_associated("target", { "id" => t1.id })

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

    ParentView.new(parent).create_or_update_associated(:children, { "name" => "c2" })

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

    ParentView.new(parent).create_or_update_associated(:children, cv)

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


    ParentView.new(p2).create_or_update_associated("children", { "id" => c1.id })

    p1.reload
    p2.reload

    assert_equal(0, p1.children.size)

    assert_equal(2, p2.children.size)
    p1c1, p1c2 = p2.children.order(:position)
    assert_equal(c2, p1c1)
    assert_equal(c1, p1c2)
  end

  # test polymorphic association
  def test_polymorphic
    skip
  end
end
