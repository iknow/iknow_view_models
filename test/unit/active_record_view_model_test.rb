# -*- coding: utf-8 -*-

require_relative "../helpers/test_models.rb"

require "minitest/autorun"
require 'minitest/unit'

require "byebug"

require "active_record_view_model"

class ActiveRecordViewModelTest < ActiveSupport::TestCase

  def setup
    # TODO make a `has_list?` that allows a parent to set all children as an array
    @parent1 = Parent.new(name: "p1",
                          children: [Child.new(name: "p1c1").tap { |c| c.position = 1 },
                                     Child.new(name: "p1c2").tap { |c| c.position = 2 },
                                     Child.new(name: "p1c3").tap { |c| c.position = 3 }],
                          label: Label.new(text: "p1l"),
                          target: Target.new(text: "p1t"),
                          poly: PolyOne.new(number: 1),
                          category: Category.new(name: "p1cat"))
    @parent1.save!

    @parent2 = Parent.new(name: "p2",
                          children: [Child.new(name: "p2c1").tap { |c| c.position = 1 },
                                     Child.new(name: "p2c2").tap { |c| c.position = 2 }],
                          label: Label.new(text: "p2l"))

    @parent2.save!

    @category1 = Category.create(name: "Cat1")

    # Enable logging for the test
    ActiveRecord::Base.logger = Logger.new(STDOUT)
  end

  def teardown
    ActiveRecord::Base.logger = nil
  end

  def test_find
    parentview = Views::Parent.find(@parent1.id)
    assert_equal(@parent1, parentview.model)

    child = @parent1.children.first
    childview = parentview.find_associated(:children, child.id)
    assert_equal(child, childview.model)
  end

  def test_load
    parentviews = Views::Parent.load
    assert_equal(2, parentviews.size)

    h = parentviews.index_by(&:id)
    assert_equal(@parent1, h[@parent1.id].model)
    assert_equal(@parent2, h[@parent2.id].model)
  end

  def test_visibility
    parentview = Views::Parent.new(@parent1)

    assert_raises(ViewModel::SerializationError) do
      no_view_context = Views::Parent.context_class.new(can_view: false)
      parentview.to_hash(view_context: no_view_context)
    end
  end

  def test_editability
    no_edit_context = Views::Parent.context_class.new(can_edit: false)

    assert_raises(ViewModel::DeserializationError) do
      # create
      Views::Parent.deserialize_from_view({ "_type" => "Parent", "name" => "p" }, view_context: no_edit_context)
    end

    assert_raises(ViewModel::DeserializationError) do
      # edit
      v = Views::Parent.new(@parent1).to_hash.merge("name" => "p2")
      Views::Parent.deserialize_from_view(v, view_context: no_edit_context)
    end

    skip("Unimplemented")

    assert_raises(ViewModel::DeserializationError) do
      # destroy
      Views::Parent.new(@parent1).destroy!(view_context: no_edit_context)
    end

    assert_raises(ViewModel::DeserializationError) do
      # append child
      Views::Parent.new(@parent1).deserialize_associated(:children, { "_type" => "Child", "text" => "hi" }, view_context: no_edit_context)
    end

    assert_raises(ViewModel::DeserializationError) do
      # replace children
      Views::Parent.new(@parent1).deserialize_associated(:children, [{"_type" => "Child", "text" => "hi" }], view_context: no_edit_context)
    end

    assert_raises(ViewModel::DeserializationError) do
      # destroy child
      Views::Parent.new(@parent1).delete_associated(:target, Views::Target.new(@parent1.target), view_context: no_edit_context)
    end
  end

  def test_serialize_view
    s = Views::Parent.new(@parent1)
    assert_equal({ "_type" => "Parent",
                   "id" => @parent1.id,
                   "name" => @parent1.name,
                   "label" => { "_type" => "Label",
                                "id" => @parent1.label.id,
                                "text" => @parent1.label.text },
                   "target" => { "_type" => "Target",
                                 "id" => @parent1.target.id,
                                 "text" => @parent1.target.text,
                                 "label" => nil },
                   "category" => nil,
                   "poly" => { "_type" => @parent1.poly_type,
                               "id" => @parent1.poly.id,
                               "number" => @parent1.poly.number },
                   "children" => @parent1.children.map { |child| { "_type" => "Child",
                                                                   "id" => child.id,
                                                                   "name" => child.name,
                                                                   "age" => nil } } },
                s.to_hash)
  end

  def test_eager_includes
    p = Views::Parent.eager_includes
    assert_equal({ "children" => {}, "category" => {}, "label" => {}, "target" => { "label" => {} }, "poly" => nil }, p)
  end

  def test_create_from_view
    view = {
      "_type" => "Parent",
      "name" => "p",
      "label" => { "_type" => "Label", "text" => "l" },
      "target" => { "_type" => "Target", "text" => "t" },
      "children" => [{ "_type" => "Child", "name" => "c1" },
                     { "_type" => "Child", "name" => "c2" }],
      "poly" => { "_type" => "PolyTwo", "text" => "pol" }
    }

    pv = Views::Parent.deserialize_from_view(view)
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
       "_type" => "Parent",
      "children" => nil
    }
    assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(view)
    end
  end

  def test_bad_multiple_association
    view = {
      "target" => []
    }
    assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(view)
    end
  end

  def test_create_without_polymorphic_type
    view = {
       "_type" => "Parent",
      "name" => "p",
      "poly" => { "text" => "pol" }
    }

    assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(view)
    end
  end

  def test_change_polymorphic_type
    # @parent1 has a PolyOne in #setup
    old_poly = @parent1.poly

    view = {
      "_type" => "Parent",
      "id" => @parent1.id,
      "poly" => { "_type" => "PolyTwo" }
    }

    Views::Parent.deserialize_from_view(view)

    @parent1.reload

    assert_instance_of(PolyTwo, @parent1.poly)
    assert_equal(false, PolyOne.exists?(old_poly.id))
  end

  def test_edit_attribute_from_view
    view = Views::Parent.new(@parent1).to_hash

    view["name"] = "renamed"
    Views::Parent.deserialize_from_view(view)

    @parent1.reload
    assert_equal("renamed", @parent1.name)
  end

  ### Test Associations
  ### has_many

  def test_has_many_empty_association
    #create
    view = { "_type" => "Parent", "name" => "p", "children" => [] }
    pv = Views::Parent.deserialize_from_view(view)
    p = pv.model
    assert(p.children.blank?)

    # update
    h = pv.to_hash
    child = Child.new(name: "x")
    p.children << child
    p.save!

    Views::Parent.deserialize_from_view(h)
    p.reload
    assert(p.children.blank?)
    assert(Child.where(id: child.id).blank?)
  end

  def test_replace_has_many
    view = Views::Parent.new(@parent1).to_hash
    old_children = @parent1.children

    view["children"] = [{ "_type" => "Child", "name" => "new_child" }]
    Views::Parent.deserialize_from_view(view)

    @parent1.reload
    assert_equal(1, @parent1.children.size)
    old_children.each { |child| assert_not_equal(child, @parent1.children.first) }
    assert_equal("new_child", @parent1.children.first.name)
  end

  def test_edit_has_many
    old_children = @parent1.children.order(:position).to_a
    view = Views::Parent.new(@parent1).to_hash

    view["children"].shift
    view["children"] << { "_type" => "Child", "name" => "c3" }
    Views::Parent.deserialize_from_view(view)

    @parent1.reload
    assert_equal(3, @parent1.children.size)
    tc1, tc2, tc3 = @parent1.children.order(:position)

    assert_equal(old_children[1], tc1)
    assert_equal(old_children[2], tc2)
    assert_equal("c3", tc3.name)

    assert(Child.where(id: old_children[0].id).blank?)
  end

  def test_edit_implicit_list_position
    old_children = @parent1.children.order(:position).to_a

    view = Views::Parent.new(@parent1).to_hash

    view["children"].reverse!
    view["children"].insert(1, { "_type" => "Child", "name" => "c3" })

    Views::Parent.deserialize_from_view(view)

    @parent1.reload
    assert_equal(4, @parent1.children.size)
    tc1, tc2, tc3, tc4 = @parent1.children.order(:position)

    assert_equal(old_children[2], tc1)
    assert_equal("c3", tc2.name)
    assert_equal(old_children[1], tc3)
    assert_equal(old_children[0], tc4)
  end

  def test_move_child_to_new
    child = @parent1.children[1]

    child_view = Views::Child.new(child).to_hash

    view = { "_type" => "Parent",
             "name" => "new_p",
             "children" => [child_view, { "_type" => "Child", "name" => "new" }] }

    release_view = { "_type" => "Parent", "id" => @parent1.id,
                     "children" => [{ "_type" => "Child", "id" => @parent1.children[0].id},
                                    { "_type" => "Child", "id" => @parent1.children[2].id}]}

    pv = Views::Parent.deserialize_from_view([view, release_view])

    new_parent = pv.first.model
    new_parent.reload

    # child should be removed from old parent and positions updated
    @parent1.reload
    assert_equal(2, @parent1.children.size, "child removed from existing parent")
    oc1, oc2 = @parent1.children.order(:position)
    assert_equal("p1c1", oc1.name, "child1 name preserved")
    assert_equal("p1c3", oc2.name, "child3 name preserved")

    # child should be added to new parent with valid position
    assert_equal(2, new_parent.children.size)
    nc1, nc2 = new_parent.children.order(:position)
    assert_equal(child, nc1)
    assert_equal("p1c2", nc1.name)
    assert_equal("new", nc2.name)
  end

  def test_move_child_to_existing
    child = @parent1.children[1]

    view = Views::Parent.new(@parent2).to_hash
    view["children"] << Views::Child.new(child).to_hash

    release_view = { "_type" => "Parent", "id" => @parent1.id,
                     "children" => [{ "_type" => "Child", "id" => @parent1.children[0].id},
                                    { "_type" => "Child", "id" => @parent1.children[2].id}]}

    Views::Parent.deserialize_from_view([view, release_view])

    @parent1.reload
    @parent2.reload

    # child should be removed from old parent and positions updated
    assert_equal(2, @parent1.children.size)
    oc1, oc2 = @parent1.children.order(:position)
    assert_equal("p1c1", oc1.name)
    assert_equal("p1c3", oc2.name)

    # child should be added to new parent with valid position
    assert_equal(3, @parent2.children.size)
    nc1, nc2, nc3 = @parent2.children.order(:position)

    assert_equal("p2c1", nc1.name)

    assert_equal("p2c2", nc2.name)

    assert_equal(child, nc3)
    assert_equal("p1c2", nc3.name)
  end

  def test_swap_has_one
    p1 = Parent.create
    p2 = Parent.create

    t1 = Target.create(parent: p1)
    t2 = Target.create(parent: p2)

    pcvs = Views::Parent.deserialize_from_view(
          [{ "id" => p1.id,
             "_type" => "Parent",
             "target" => { "id" => t2.id, "_type" => "Target" } },
           { "id" => p2.id,
             "_type" => "Parent",
             "target" => { "id" => t1.id, "_type" => "Target" } }])


    p1.reload
    p2.reload

    assert_equal(p1.target, t2)
    assert_equal(p2.target, t1)
  end

  def test_move_and_edit_child_to_new
    child = @parent1.children[1]

    child_view = Views::Child.new(child).to_hash
    child_view["name"] = "changed"

    view = { "_type" => "Parent",
             "name" => "new_p",
             "children" => [child_view, { "_type" => "Child", "name" => "new" }]}

    release_view = { "_type" => "Parent",
                     "id" => @parent1.id,
                     "children" => [{ "_type" => "Child", "id" => @parent1.children[0].id }, { "_type" => "Child", "id" => @parent1.children[2].id }]}

    pv = Views::Parent.deserialize_from_view([view, release_view])
    new_parent = pv.first.model

    # child should be removed from old parent and positions updated
    @parent1.reload
    assert_equal(2, @parent1.children.size, "database has 2 children")
    oc1, oc2 = @parent1.children.order(:position)
    assert_equal("p1c1", oc1.name, "database c1 unchanged")
    assert_equal("p1c3", oc2.name, "database c2 unchanged")

    # child should be added to new parent with valid position
    assert_equal(2, new_parent.children.size, "viewmodel has 2 children")
    nc1, nc2 = new_parent.children.order(:position)
    assert_equal(child, nc1)
    assert_equal("changed", nc1.name)
    assert_equal("new", nc2.name)
  end

  def test_move_and_edit_child_to_existing
    old_child = @parent1.children[1]

    old_child_view = Views::Child.new(old_child).to_hash
    old_child_view["name"] = "changed"
    view = Views::Parent.new(@parent2).to_hash
    view["children"] << old_child_view

    release_view = {"_type" => "Parent", "id" => @parent1.id,
                    "children" => [{"_type" => "Child", "id" => @parent1.children[0].id},
                                   {"_type" => "Child", "id" => @parent1.children[2].id}]}

    Views::Parent.deserialize_from_view([view, release_view])

    @parent1.reload
    @parent2.reload

    # child should be removed from old parent and positions updated
    assert_equal(2, @parent1.children.size)
    oc1, oc2 = @parent1.children.order(:position)

    assert_equal("p1c1", oc1.name)
    assert_equal("p1c3", oc2.name)

    # child should be added to new parent with valid position
    assert_equal(3, @parent2.children.size)
    nc1, nc2, nc3 = @parent2.children.order(:position)
    assert_equal("p2c1", nc1.name)

    assert_equal("p2c1", nc1.name)

    assert_equal(old_child, nc3)
    assert_equal("changed", nc3.name)
  end

  ### belongs_to

  def test_belongs_to_nil_association
    # create
    view = { "_type" => "Parent", "name" => "p", "label" => nil }
    pv = Views::Parent.deserialize_from_view(view)
    p = pv.model
    assert_nil(p.label)

    # update
    h = pv.to_hash
    p.label = label = Label.new(text: "hello")
    p.save!

    Views::Parent.deserialize_from_view(h)
    p.reload
    assert_nil(p.label)
    assert(Label.where(id: label.id).blank?)
  end

  # def test_rails_bewat
  #   p1 = Parent.create
  #   p2 = Parent.create
  #
  #   label = Label.create
  #   p1.label = label
  #   p1.save!
  #   #label.save!
  #
  #   #p1.label_id = nil
  #   p2.label = label
  #   p1.save!
  #
  #   label.save!
  #
  # end
  #
  # def test_rails_naive_swap
  #   p1 = Parent.create
  #   p2 = Parent.create
  #
  #   target1 = Target.create(parent: p1)
  #   target2 = Target.create(parent: p2)
  #
  #   p1.target = target2
  #   p2.target = target1
  #   p1.save!
  #   p2.save!
  #
  # end


  def test_belongs_to_create
    @parent1.label = nil
    @parent1.save!
    @parent1.reload

    view = Views::Parent.new(@parent1).to_hash
    view["label"] = { "_type" => "Label", "text" => "cheese" }

    Views::Parent.deserialize_from_view(view)
    @parent1.reload

    assert(@parent1.label.present?)
    assert_equal("cheese", @parent1.label.text)
  end

  def test_belongs_to_replace
    old_label = @parent1.label

    view = Views::Parent.new(@parent1).to_hash
    view["label"] = { "_type" => "Label", "text" => "cheese" }

    Views::Parent.deserialize_from_view(view)
    @parent1.reload

    assert(@parent1.label.present?)
    assert_equal("cheese", @parent1.label.text)
    assert(Label.where(id: old_label).blank?)
  end

  def test_belongs_to_move_and_replace
    old_p2_label = @parent2.label

    v1 = Views::Parent.new(@parent1).to_hash
    v2 = Views::Parent.new(@parent2).to_hash

    # move l1 to p2
    # l2 should be garbage collected
    # p1 should now have no label

    v2["label"] = v1["label"]
    v1["label"] = nil

    Views::Parent.deserialize_from_view([v2, v1])

    @parent1.reload
    @parent2.reload

    assert(@parent1.label.blank?)
    assert(@parent2.label.present?)
    assert_equal("p1l", @parent2.label.text)
    assert(Label.where(id: old_p2_label).blank?)
  end

  def test_belongs_to_build_new_association
    skip("unimplemented")

    old_label = @parent1.label

    Views::Parent.new(@parent1).deserialize_associated(:label, { "text" => "l2" })

    @parent1.reload

    assert(Label.where(id: old_label.id).blank?)
    assert_equal("l2", @parent1.label.text)
  end

  def test_belongs_to_update_existing_association
    skip("unimplemented")

    label = @parent1.label
    lv = Views::Label.new(label).to_hash
    lv["text"] = "renamed"

    Views::Parent.new(@parent1).deserialize_associated(:label, lv)

    @parent1.reload

    assert_equal(label, @parent1.label)
    assert_equal("renamed", @parent1.label.text)
  end

  def test_belongs_to_move_existing_association
    skip("unimplemented")

    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    Views::Parent.new(@parent2).deserialize_associated("label", { "id" => old_p1_label.id })

    @parent1.reload
    @parent2.reload

    assert(@parent1.label.blank?)
    assert(Label.where(id: old_p2_label.id).blank?)

    assert_equal(old_p1_label, @parent2.label)
    assert_equal("p1l", @parent2.label.text)
  end

  # test belongs_to garbage collection - dependent: delete_all
  def test_gc_dependent_delete_all
    o = Owner.create(deleted: Label.new(text: "one"))
    l = o.deleted

    ov = Views::Owner.new(o).to_hash
    ov["deleted"] = { "_type" => "Label", "text" => "two" }
    Views::Owner.deserialize_from_view(ov)

    o.reload

    assert_equal("two", o.deleted.text)
    assert(l != o.deleted)
    assert(Label.where(id: l.id).blank?)
  end

  def test_no_gc_dependent_ignore
    o = Owner.create(ignored: Label.new(text: "one"))
    l = o.ignored

    ov = Views::Owner.new(o).to_hash
    ov["ignored"] = { "_type" => "Label", "text" => "two" }
    Views::Owner.deserialize_from_view(ov)

    o.reload

    assert_equal("two", o.ignored.text)
    assert(l != o.ignored)
    assert_equal(1, Label.where(id: l.id).count)
  end

  ### has_one

  def test_has_one_nil_association
    # create
    view = { "_type" => "Parent", "name" => "p", "target" => nil }
    pv = Views::Parent.deserialize_from_view(view)
    p = pv.model
    assert_nil(p.target)

    # update
    h = pv.to_hash
    p.target = target = Target.new
    p.save!

    Views::Parent.deserialize_from_view(h)
    p.reload
    assert_nil(p.target)
    assert(Target.where(id: target.id).blank?)
  end

  def test_has_one_create
    p = Parent.create(name: "p")

    view = Views::Parent.new(p).to_hash
    view["target"] = { "_type" => "Target", "text" => "t" }

    Views::Parent.deserialize_from_view(view)
    p.reload

    assert(p.target.present?)
    assert_equal("t", p.target.text)
  end

  def test_has_one_move_and_replace
    @parent2.create_target(text: "p2t")

    t1 = @parent1.target
    t2 = @parent2.target

    v1 = Views::Parent.new(@parent1).to_hash
    v2 = Views::Parent.new(@parent2).to_hash

    v2["target"] = v1["target"]
    v1["target"] = nil

    Views::Parent.deserialize_from_view([v2, v1])
    @parent1.reload
    @parent2.reload

    assert(@parent1.target.blank?)
    assert(@parent2.target.present?)
    assert_equal(t1.text, @parent2.target.text)

    assert(Target.where(id: t2).blank?)
  end

  def test_has_one_build_new_association
    skip("unimplemented")

    old_target = @parent1.target
    Views::Parent.new(@parent1).deserialize_associated(:target, { "text" => "new" })

    @parent1.reload

    assert(Target.where(id: old_target.id).blank?)
    assert_equal("new", @parent1.target.text)
  end

  def test_has_one_update_existing_association
    skip("unimplemented")

    t = @parent1.target
    tv = Views::Target.new(t).to_hash
    tv["text"] = "renamed"

    Views::Parent.new(@parent1).deserialize_associated(:target, tv)

    @parent1.reload

    assert_equal(t, @parent1.target)
    assert_equal("renamed", @parent1.target.text)
  end

  def test_has_one_move_existing_association
    skip("unimplemented")

    @parent2.create_target(text: "p2t")
    t1 = @parent1.target
    t2 = @parent2.target

    Views::Parent.new(@parent2).deserialize_associated("target", { "id" => t1.id })

    @parent1.reload
    @parent2.reload

    assert(@parent1.target.blank?)
    assert(Target.where(id: t2.id).blank?)

    assert_equal(t1, @parent2.target)
    assert_equal("p1t", @parent2.target.text)
  end

  # test building extra child in association
  def test_has_many_build_new_association
    skip("unimplemented")

    Views::Parent.new(@parent1).deserialize_associated(:children, { "name" => "new" })

    @parent1.reload

    assert_equal(4, @parent1.children.size)
    lc = @parent1.children.order(:position).last
    assert_equal("new", lc.name)
  end

  def test_has_many_build_new_association_with_explicit_position
    skip("unimplemented")

    Views::Parent.new(@parent2).deserialize_associated(:children, { "name" => "new", "position" => 2 })

    @parent2.reload

    children = @parent2.children.order(:position)

    assert_equal(3, children.size)
    assert_equal(["p2c1", "new", "p2c2"], children.map(&:name))
    assert_equal([1, 2, 3], children.map(&:position))
  end

  def test_has_many_update_existing_association
    skip("unimplemented")

    child = @parent1.children[1]

    cv = Views::Child.new(child).to_hash
    cv["name"] = "newname"

    Views::Parent.new(@parent1).deserialize_associated(:children, cv)

    @parent1.reload

    assert_equal(3, @parent1.children.size)
    c1, c2, c3 = @parent1.children.order(:position)
    assert_equal("p1c1", c1.name)

    assert_equal(child, c2)
    assert_equal("newname", c2.name)

    assert_equal("p1c3", c3.name)
  end

  def test_has_many_move_existing_association
    skip("unimplemented")

    p1c2 = @parent1.children[1]
    assert_equal(2, p1c2.position)

    Views::Parent.new(@parent2).deserialize_associated("children", { "id" => p1c2.id })

    @parent1.reload
    @parent2.reload

    p1c = @parent1.children.order(:position)
    assert_equal(2, p1c.size)
    assert_equal(["p1c1", "p1c3"], p1c.map(&:name))

    p2c = @parent2.children.order(:position)
    assert_equal(3, p2c.size)
    assert_equal(["p2c1", "p2c2", "p1c2"], p2c.map(&:name))
    assert_equal(p1c2, p2c[2])
    assert_equal(3, p2c[2].position)
  end

  def test_delete_association
    skip("unimplemented")

    p1c2 = @parent1.children[1]

    Views::Parent.new(@parent1).delete_associated("children", Views::Child.new(p1c2))
    @parent1.reload

    assert_equal(2, @parent1.children.size)
    assert_equal(["p1c1", "p1c3"], @parent1.children.map(&:name))
    assert_equal([1, 2], @parent1.children.map(&:position))

    assert(Child.where(id: p1c2).blank?)
  end

  def json_reference_to(viewmodel, view_context: viewmodel.default_context)
    viewmodel.to_hash(view_context: view_context).slice("_type", "id")
  end

  def test_shared_add_reference
    p2view = Views::Parent.new(@parent2).to_hash
    p2view["category"] = json_reference_to(Views::Category.new(@category1))
    Views::Parent.deserialize_from_view(p2view)

    @parent2.reload

    assert_equal(@category1, @parent2.category)
  end

  def test_shared_delete_reference
    p1view = Views::Parent.new(@parent1).to_hash
    p1view["category"] = nil
    Views::Parent.deserialize_from_view(p1view)

    @parent1.reload

    assert_equal(nil, @parent1.category)
    assert(Category.where(id: @category1.id).present?)
  end

end
