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
                          label:    Label.new(text: "p1l"),
                          target:   Target.new(text: "p1t"),
                          poly:     PolyOne.new(number: 1),
                          category: Category.new(name: "p1cat"))
    @parent1.save!
    @parent1_view = Views::Parent.new(@parent1)

    @parent2 = Parent.new(name: "p2",
                          children: [Child.new(name: "p2c1").tap { |c| c.position = 1 },
                                     Child.new(name: "p2c2").tap { |c| c.position = 2 }],
                          label: Label.new(text: "p2l"))

    @parent2.save!
    @parent2_view = Views::Parent.new(@parent2)

    @category1 = Category.create(name: "Cat1")
    @category1_view = Views::Category.new(@category1)

    # Enable logging for the test
    ActiveRecord::Base.logger = Logger.new(STDOUT)
  end

  def teardown
    ActiveRecord::Base.logger = nil
  end

  ## Test utilities

  def serialize_with_references(serializable, view_context: Views::ApplicationView::SerializeContext.new)
    data = ViewModel.serialize_to_hash(serializable, view_context: view_context)
    references = view_context.serialize_references_to_hash
    return data, references
  end

  def serialize(serializable, view_context: Views::ApplicationView::SerializeContext.new)
    data, _ = serialize_with_references(serializable)
    data
  end

  # Construct an update hash that references an existing model. Does not include
  # any of the model's attributes or association.
  def update_hash_ref(viewmodel_class, model)
    ref = {'_type' => viewmodel_class.view_name, 'id' => model.id}
    yield(ref) if block_given?
    ref
  end

  # Test helper: update a model by manipulating the full view hash
  def alter_by_view!(viewmodel_class, model)
    models = Array.wrap(model)

    data, refs = serialize_with_references(models.map { |m| viewmodel_class.new(m) })

    if model.is_a?(Array)
      yield(data, refs)
    else
      yield(data.first, refs)
    end

    begin
      deserialize_context = Views::ApplicationView::DeserializeContext.new

      viewmodel_class.deserialize_from_view(
        data, references: refs, view_context: deserialize_context)

      deserialize_context
    ensure
      models.each { |m| m.reload }
    end
  end

  # Test helper: update a model by constructing a new view hash
  # TODO the body of this is growing longer and is mostly the same as by `alter_by_view!`.
  def set_by_view!(viewmodel_class, model)
    models = Array.wrap(model)

    data = models.map { |m| update_hash_ref(viewmodel_class, m) }
    refs = {}

    if model.is_a?(Array)
      yield(data, refs)
    else
      yield(data.first, refs)
    end

    begin
      deserialize_context = Views::ApplicationView::DeserializeContext.new

      viewmodel_class.deserialize_from_view(
        data, references: refs, view_context: Views::ApplicationView::DeserializeContext.new)

      deserialize_context
    ensure
      models.each { |m| m.reload }
    end
  end

  def count_all(enum)
    # equivalent to `group_by{|x|x}.map{|k,v| [k, v.length]}.to_h`
    enum.each_with_object(Hash.new(0)) do |x, counts|
      counts[x] += 1
    end
  end

  ## Tests

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

  def test_visibility_raises
    parentview = Views::Parent.new(@parent1)

    assert_raises(ViewModel::SerializationError) do
      no_view_context = Views::ApplicationView::SerializeContext.new(can_view: false)
      parentview.to_hash(view_context: no_view_context)
    end
  end

  def test_editability_checks_create
    context = Views::ApplicationView::DeserializeContext.new
    Views::Parent.deserialize_from_view({'_type' => 'Parent', 'name' => 'p'},
                                        view_context: context)
    assert_equal([[Views::Parent, nil]], context.edit_checks)
  end

  def test_editability_raises
    no_edit_context = Views::ApplicationView::DeserializeContext.new(can_edit: false)

    assert_raises(ViewModel::DeserializationError) do
      # create
      Views::Parent.deserialize_from_view({ "_type" => "Parent", "name" => "p" }, view_context: no_edit_context)
    end

    assert_raises(ViewModel::DeserializationError) do
      # edit
      v = Views::Parent.new(@parent1).to_hash.merge("name" => "p2")
      Views::Parent.deserialize_from_view(v, view_context: no_edit_context)
    end

    assert_raises(ViewModel::DeserializationError) do
      # destroy
      Views::Parent.new(@parent1).destroy!(view_context: no_edit_context)
    end

    skip("unimplemented")

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

  def test_serialize_view_minimal
    empty_parent_view = Views::Parent.new(p = Parent.create).to_hash

    assert_equal({ '_type'    => 'Parent',
                   'id'       => p.id,
                   'name'     => nil,
                   'children' => [],
                   'label'    => nil,
                   'target'   => nil,
                   'poly'     => nil,
                   'category' => nil,
                 }, empty_parent_view,
                 'all keys are present in default view')
  end

  def test_serialize_view
    view, refs = serialize_with_references(Views::Parent.new(@parent1))
    cat1_ref = refs.detect { |_, v| v['_type'] == 'Category'  }.first

    assert_equal({cat1_ref => { '_type' => "Category",
                                'id'    => @parent1.category.id,
                                'name'  => @parent1.category.name }},
                 refs)

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
                   "category" => {"_ref" => cat1_ref},
                   "poly" => { "_type" => @parent1.poly_type,
                               "id" => @parent1.poly.id,
                               "number" => @parent1.poly.number },
                   "children" => @parent1.children.map { |child| { "_type" => "Child",
                                                                   "id" => child.id,
                                                                   "name" => child.name,
                                                                   "age" => nil } } },
                view)
  end

  def test_eager_includes
    parent_includes = Views::Parent.eager_includes

    assert_equal({ 'children' => {},
                   'category' => {},
                   'label'    => {},
                   'target'   => { 'label' => {} },
                   'poly'     => nil },
                 parent_includes)
  end

  def test_create_from_view
    view = {
      "_type"    => "Parent",
      "name"     => "p",
      "label"    => { "_type" => "Label", "text" => "l" },
      "target"   => { "_type" => "Target", "text" => "t" },
      "children" => [{ "_type" => "Child", "name" => "c1" },
                     { "_type" => "Child", "name" => "c2" }],
      "poly"     => { "_type" => "PolyTwo", "text" => "pol" }
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

  def test_create_invalid_type
    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view({ "target" => [] })
    end
    assert_match(/\b_type\b.*\battribute missing/, ex.message)

    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view({ "_type" => "Child" })
    end
    assert_match(/incorrect root viewmodel type/, ex.message)

    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view({ "_type" => "NotAViewmodelType" })
    end
    assert_match(/ViewModel\b.*\bnot found/, ex.message)
  end

  def test_bad_single_association
    view = {
      "_type" => "Parent",
      "target" => []
    }
    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(view)
    end
    assert_match(/not a hash/, ex.message)
  end

  def test_bad_multiple_association
    view = {
       "_type" => "Parent",
      "children" => nil
    }
    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(view)
    end

    assert_match(/Invalid hash data array for multiple association/, ex.message)
  end

  def test_change_polymorphic_type
    # @parent1 has a PolyOne in #setup
    old_poly = @parent1.poly

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['poly'] = { '_type' => 'PolyTwo' }
    end

    assert_instance_of(PolyTwo, @parent1.poly)
    assert_equal(false, PolyOne.exists?(old_poly.id))
  end

  def test_edit_attribute_from_view
    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['name'] = 'renamed'
    end
    assert_equal('renamed', @parent1.name)
  end

  def test_edit_attribute_validation_failure
    old_name = @parent1.name
    assert_raises(ActiveRecord::RecordInvalid) do
      alter_by_view!(Views::Parent, @parent1) do |view, refs|
        view['name'] = 'invalid'
      end
    end
    assert_equal(old_name, @parent1.name, 'validation failure causes rollback')
  end

  ### Test Associations
  ### has_many

  def test_create_has_many_empty
    view = { '_type' => 'Parent', 'name' => 'p', 'children' => [] }
    pv = Views::Parent.deserialize_from_view(view)
    assert(pv.model.children.blank?)
  end

  def test_create_has_many
    view = { '_type'    => 'Parent',
             'name'     => 'p',
             'children' => [{ '_type' => 'Child', 'name' => 'c1' },
                            { '_type' => 'Child', 'name' => 'c2' }] }

    context = Views::ApplicationView::DeserializeContext.new
    pv = Views::Parent.deserialize_from_view(view, view_context: context)

    assert_equal({ [Views::Parent, nil] => 1,
                   [Views::Child,  nil] => 2 },
                 count_all(context.edit_checks))

    assert_equal(%w(c1 c2), pv.model.children.map(&:name))
  end

  def test_replace_has_many
    old_children = @parent1.children

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['children'] = [{ '_type' => 'Child', 'name' => 'new_child' }]
    end

    assert_equal(['new_child'], @parent1.children.map(&:name))
    assert_equal([], Child.where(id: old_children.map(&:id)))
  end

  def test_remove_has_many
    old_children = @parent1.children
    context = alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['children'] = []
    end

    assert_equal(Set.new([[Views::Parent, @parent1.id]] +
                           [old_children.map { |x| [Views::Child, x.id] }]),
                 context.edit_checks.to_set)

    assert_equal([], @parent1.children, 'no children associated with parent1')
    assert(Child.where(id: old_children.map(&:id)).blank?, 'all children deleted')
  end

  def test_edit_has_many
    c1, c2, c3 = @parent1.children.order(:position).to_a
    context = alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['children'].shift
      view['children'] << { '_type' => 'Child', 'name' => 'new_c' }
    end

    assert_equal({ [Views::Parent, @parent1.id] => 1,
                   [Views::Child,  nil]         => 1 },
                 count_all(context.edit_checks))

    assert_equal([c2, c3, Child.find_by_name('new_c')],
                 @parent1.children.order(:position))
    assert(Child.where(id: c1.id).blank?)
  end

  def test_edit_implicit_list_position
    c1, c2, c3 = @parent1.children.order(:position).to_a

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['children'].reverse!
      view['children'].insert(1, { '_type' => 'Child', 'name' => 'new_c' })
    end

    assert_equal([c3, Child.find_by_name('new_c'), c2, c1],
                 @parent1.children.order(:position))
  end

  def test_move_child_to_new
    old_children = @parent1.children.order(:position)
    moved_child = old_children[1]

    moved_child_ref = update_hash_ref(Views::Child, moved_child)

    view = { '_type'    => 'Parent',
             'name'     => 'new_p',
             'children' => [moved_child_ref,
                            { '_type' => 'Child', 'name' => 'new' }] }

    retained_children = old_children - [moved_child]
    release_view = { '_type'    => 'Parent',
                     'id'       => @parent1.id,
                     'children' => retained_children.map { |c| update_hash_ref(Views::Child, c) } }

    pv = Views::Parent.deserialize_from_view([view, release_view])

    new_parent = pv.first.model
    new_parent.reload

    # child should be removed from old parent
    @parent1.reload
    assert_equal(retained_children,
                 @parent1.children.order(:position))

    # child should be added to new parent
    new_children = new_parent.children.order(:position)
    assert_equal(%w(p1c2 new), new_children.map(&:name))
    assert_equal(moved_child, new_children.first)
  end

  def test_move_child_to_new_with_implicit_release
    old_children = @parent1.children.order(:position)
    moved_child = old_children[1]
    retained_children = old_children - [moved_child]

    moved_child_ref = update_hash_ref(Views::Child, moved_child)

    view = { '_type'    => 'Parent',
             'name'     => 'new_p',
             'children' => [moved_child_ref,
                            { '_type' => 'Child', 'name' => 'new' }] }

    view_context = Views::ApplicationView::DeserializeContext.new

    new_parent_view = Views::Parent.deserialize_from_view(view, view_context: view_context)

    new_parent = new_parent_view.model
    new_parent.reload

    assert_equal({ [Views::Parent, nil]           => 1,
                   [Views::Child,  nil]           => 1,
                   [Views::Child,  moved_child.id]=> 1,
                   [Views::Parent, @parent1.id]   => 1 },
                 count_all(view_context.edit_checks))

    # child should be removed from old parent
    @parent1.reload
    assert_equal(retained_children,
                 @parent1.children.order(:position))

    # child should be added to new parent
    new_children = new_parent.children.order(:position)
    assert_equal(%w(p1c2 new), new_children.map(&:name))
    assert_equal(moved_child, new_children.first)
  end

  def test_implicit_release_has_many
    old_children = @parent1.children.order(:position)
    view = {'_type'    => 'Parent',
            'name'     => 'newp',
            'children' => old_children.map { |x| update_hash_ref(Views::Child, x) }}

    new_parent_model = Views::Parent.deserialize_from_view(view).model

    @parent1.reload
    new_parent_model.reload

    assert_equal([], @parent1.children)
    assert_equal(old_children,
                 new_parent_model.children.order(:position))
  end

  def test_implicit_release_invalid
    old_children = @parent1.children.order(:position)
    old_children_refs = old_children.map { |x| update_hash_ref(Views::Child, x) }

    assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(
        [{ '_type'    => 'Parent',
           'name'     => 'newp',
           'children' => old_children_refs },
         update_hash_ref(Views::Parent, @parent1) { |p1v| p1v['name'] = 'p1 new name' }])
    end
  end

  def test_move_child_to_existing
    old_children = @parent1.children.order(:position)
    moved_child = old_children[1]

    view = Views::Parent.new(@parent2).to_hash
    view['children'] << Views::Child.new(moved_child).to_hash

    retained_children = old_children - [moved_child]
    release_view = { '_type' => 'Parent', 'id' => @parent1.id,
                     'children' => retained_children.map { |c| update_hash_ref(Views::Child, c) }}

    Views::Parent.deserialize_from_view([view, release_view])

    @parent1.reload
    @parent2.reload

    # child should be removed from old parent and positions updated
    assert_equal(retained_children, @parent1.children.order(:position))

    # child should be added to new parent with valid position
    new_children = @parent2.children.order(:position)
    assert_equal(%w(p2c1 p2c2 p1c2), new_children.map(&:name))
    assert_equal(moved_child, new_children.last)
  end

  def test_swap_has_one
    @parent1.update(target: t1 = Target.new)
    @parent2.update(target: t2 = Target.new)

    view_context = Views::ApplicationView::DeserializeContext.new

    Views::Parent.deserialize_from_view(
      [update_hash_ref(Views::Parent, @parent1) { |p| p['target'] = update_hash_ref(Views::Target, t2) },
       update_hash_ref(Views::Parent, @parent2) { |p| p['target'] = update_hash_ref(Views::Target, t1) }],
      view_context: view_context)

    assert_equal(Set.new([[Views::Parent, @parent1.id],
                          [Views::Parent, @parent2.id],
                          [Views::Target, t1.id],
                          [Views::Target, t2.id]]),
                 view_context.edit_checks.to_set)

    @parent1.reload
    @parent2.reload

    assert_equal(@parent1.target, t2)
    assert_equal(@parent2.target, t1)
  end

  def test_move_and_edit_child_to_new
    child = @parent1.children[1]

    child_view = Views::Child.new(child).to_hash
    child_view["name"] = "changed"

    view = { "_type" => "Parent",
             "name" => "new_p",
             "children" => [child_view, { "_type" => "Child", "name" => "new" }]}

    # TODO this is as awkward here as it is in the application
    release_view = { "_type" => "Parent",
                     "id" => @parent1.id,
                     "children" => [{ "_type" => "Child", "id" => @parent1.children[0].id },
                                    { "_type" => "Child", "id" => @parent1.children[2].id }]}

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

  def test_create_belongs_to_nil
    view = { '_type' => 'Parent', 'name' => 'p', 'label' => nil }
    pv = Views::Parent.deserialize_from_view(view)
    assert_nil(pv.model.label)
  end

  def test_belongs_to_create
    @parent1.update(label: nil)

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['label'] = { '_type' => 'Label', 'text' => 'cheese' }
    end

    assert_equal('cheese', @parent1.label.text)
  end

  def test_belongs_to_replace
    old_label = @parent1.label

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['label'] = { '_type' => 'Label', 'text' => 'cheese' }
    end

    assert_equal('cheese', @parent1.label.text)
    assert(Label.where(id: old_label).blank?)
  end

  def test_belongs_to_move_and_replace
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    set_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
      p1['label'] = nil
      p2['label'] = update_hash_ref(Views::Label, old_p1_label)
    end

    assert(@parent1.label.blank?, 'l1 label reference removed')
    assert_equal(old_p1_label, @parent2.label, 'p2 has label from p1')
    assert(Label.where(id: old_p2_label).blank?, 'p2 old label deleted')
  end

  def test_belongs_to_swap
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
      p1['label'] = update_hash_ref(Views::Label, old_p2_label)
      p2['label'] = update_hash_ref(Views::Label, old_p1_label)
    end

    assert_equal(old_p2_label, @parent1.label, 'p1 has label from p2')
    assert_equal(old_p1_label, @parent2.label, 'p2 has label from p1')
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
    owner = Owner.create(deleted: Label.new(text: 'one'))
    old_label = owner.deleted

    alter_by_view!(Views::Owner, owner) do |ov, refs|
      ov['deleted'] = { '_type' => 'Label', 'text' => 'two' }
    end

    assert_equal('two', owner.deleted.text)
    refute_equal(old_label, owner.deleted)
    assert(Label.where(id: old_label.id).blank?)
  end

  def test_no_gc_dependent_ignore
    owner = Owner.create(ignored: Label.new(text: "one"))
    old_label = owner.ignored

    alter_by_view!(Views::Owner, owner) do |ov, refs|
      ov['ignored'] = { '_type' => 'Label', 'text' => 'two' }
    end
    assert_equal('two', owner.ignored.text)
    refute_equal(old_label, owner.ignored)
    assert_equal(1, Label.where(id: old_label.id).count)
  end

  ### has_one

  def test_has_one_create_nil
    view = { '_type' => 'Parent', 'name' => 'p', 'target' => nil }
    pv = Views::Parent.deserialize_from_view(view)
    assert_nil(pv.model.target)
  end

  def test_has_one_create
    @parent1.update(target: nil)

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['target'] = { '_type' => 'Target', 'text' => 't' }
    end

    assert_equal('t', @parent1.target.text)
  end

  def test_has_one_destroy
    old_target = @parent1.target
    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['target'] = nil
    end
    assert(Target.where(id: old_target.id).blank?)
  end

  def test_has_one_move_and_replace
    @parent2.create_target(text: 'p2t')

    old_parent1_target = @parent1.target
    old_parent2_target = @parent2.target

    alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
      p2['target'] = p1['target']
      p1['target'] = nil
    end

    assert(@parent1.target.blank?)
    assert_equal(old_parent1_target, @parent2.target)
    assert(Target.where(id: old_parent2_target).blank?)
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

  def test_shared_add_reference
    alter_by_view!(Views::Parent, @parent2) do |p2view, refs|
      p2view['category'] = {'_ref' => 'myref'}
      refs['myref'] = update_hash_ref(Views::Category, @category1)
    end

    assert_equal(@category1, @parent2.category)
  end

  def test_shared_add_multiple_references
    alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1view, p2view), refs|
      refs.delete(p1view['category']['_ref'])
      refs['myref'] = update_hash_ref(Views::Category, @category1)

      p1view['category'] = { '_ref' => 'myref' }
      p2view['category'] = { '_ref' => 'myref' }
    end

    assert_equal(@category1, @parent1.category)
    assert_equal(@category1, @parent2.category)
  end

  def test_shared_requires_all_references
    ex = assert_raises(ViewModel::DeserializationError) do
      alter_by_view!(Views::Parent, @parent2) do |p2view, refs|
        refs['spurious_ref'] = { '_type' => 'Parent', 'id' => @parent1.id }
      end
    end
    assert_match(/was not referred to/, ex.message)
  end

  def test_shared_requires_valid_references
    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(@parent1_view.to_hash) # no references:
    end
    assert_match(/Could not find referenced/, ex.message)
  end

  def test_shared_requires_assignable_type
    ex = assert_raises(ViewModel::DeserializationError) do
      alter_by_view!(Views::Parent, @parent1) do |p1view, refs|
        p1view['category'] = { '_ref' => 'p2' }
        refs['p2'] = update_hash_ref(Views::Parent, @parent2)
      end
    end
    assert_match(/can't refer to/, ex.message)
  end

  def test_shared_requires_unique_references
    c1_ref = update_hash_ref(Views::Category, @category1)
    ex = assert_raises(ViewModel::DeserializationError) do
      alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1view, p2view), refs|
        refs['c_a'] = c1_ref.dup
        refs['c_b'] = c1_ref.dup
        p1view['category'] = { '_ref' => 'c1' }
        p2view['category'] = { '_ref' => 'c2' }
      end
    end
    assert_match(/Duplicate/, ex.message)
  end

  def test_shared_updates_shared_data
    alter_by_view!(Views::Parent, @parent1) do |p1view, refs|
      category_ref = p1view['category']['_ref']
      refs[category_ref]['name'] = 'newcatname'
    end
    assert_equal('newcatname', @parent1.category.name)
  end

  def test_shared_delete_reference
    alter_by_view!(Views::Parent, @parent1) do |p1view, refs|
      category_ref = p1view['category']['_ref']
      refs.delete(category_ref)
      p1view['category'] = nil
    end
    assert_equal(nil, @parent1.category)
    assert(Category.where(id: @category1.id).present?)
  end

end
