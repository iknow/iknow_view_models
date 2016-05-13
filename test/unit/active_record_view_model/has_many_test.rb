require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

class ActiveRecordViewModel::HasManyTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:Parent) do
      define_schema do |t|
        t.string :name
      end

      define_model do
        has_many :children, dependent: :destroy, inverse_of: :parent
      end

      define_viewmodel do
        attributes :name
        associations :children
        include TrivialAccessControl
      end
    end

    build_viewmodel(:Child) do
      define_schema do |t|
        t.references :parent, null: false, foreign_key: true
        t.string :name
        t.float :position
      end

      define_model do
        belongs_to :parent, inverse_of: :children
        acts_as_manual_list scope: :parent
      end

      define_viewmodel do
        attributes :name
        acts_as_list :position

        include TrivialAccessControl
      end
    end
  end

  def setup
    @parent1 = Parent.new(name: "p1",
                          children: [Child.new(name: "p1c1", position: 1),
                                     Child.new(name: "p1c2", position: 2),
                                     Child.new(name: "p1c3", position: 3)])
    @parent1.save!

    @parent2 = Parent.new(name: "p2",
                          children: [Child.new(name: "p2c1").tap { |c| c.position = 1 },
                                     Child.new(name: "p2c2").tap { |c| c.position = 2 }])

    @parent2.save!
    super
  end

  def test_find_associated
    parentview = Views::Parent.find(@parent1.id)
    child = @parent1.children.first
    childview = parentview.find_associated(:children, child.id)
    assert_equal(child, childview.model)
  end

  def test_serialize_view
    view, _refs = serialize_with_references(Views::Parent.new(@parent1))


    assert_equal({ "_type" => "Parent",
                   "id" => @parent1.id,
                   "name" => @parent1.name,
                   "children" => @parent1.children.map { |child| { "_type" => "Child",
                                                                   "id" => child.id,
                                                                   "name" => child.name } } },
                 view)
  end

  def test_create_from_view
    view = {
      "_type"    => "Parent",
      "name"     => "p",
      "children" => [{ "_type" => "Child", "name" => "c1" },
                     { "_type" => "Child", "name" => "c2" }]
    }

    pv = Views::Parent.deserialize_from_view(view)
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

  def test_editability_raises
    no_edit_context = Views::Parent.new_deserialize_context(can_edit: false)

    assert_raises(ViewModel::DeserializationError) do
      # append child
      Views::Parent.new(@parent1).append_associated(:children, { "_type" => "Child", "text" => "hi" }, deserialize_context: no_edit_context)
    end

    assert_raises(ViewModel::DeserializationError) do
      # destroy child
      Views::Parent.new(@parent1).delete_associated(:target, Views::Child.new(@parent1.children.first), deserialize_context: no_edit_context)
    end
  end

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

    context = Views::ApplicationBase::DeserializeContext.new
    pv = Views::Parent.deserialize_from_view(view, deserialize_context: context)

    assert_equal({ [Views::Parent, nil] => 1,
                   [Views::Child,  nil] => 2 },
                 count_all(context.edit_checks))

    assert_equal(%w(c1 c2), pv.model.children.map(&:name))
  end

  def test_nil_multiple_association
    view = {
       "_type" => "Parent",
      "children" => nil
    }
    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(view)
    end

    assert_match(/Invalid hash data array for multiple association/, ex.message)
  end

  def test_non_array_multiple_association
    view = {
      "_type" => "Parent",
      "children" => { '_type' => 'Child', 'name' => 'c1' }
    }
    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(view)
    end

    assert_match(/Could not parse non-array collection association/, ex.message)
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

    assert_equal(Set.new([[Views::Parent, @parent1.id]]).merge(old_children.map { |x| [Views::Child, x.id] }),
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
                   [Views::Child,  c1.id]       => 1, # deleted child
                   [Views::Child,  nil]         => 1, # created child
                 },
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

    moved_child_ref = update_hash_for(Views::Child, moved_child)

    view = { '_type'    => 'Parent',
             'name'     => 'new_p',
             'children' => [moved_child_ref,
                            { '_type' => 'Child', 'name' => 'new' }] }

    retained_children = old_children - [moved_child]
    release_view = { '_type'    => 'Parent',
                     'id'       => @parent1.id,
                     'children' => retained_children.map { |c| update_hash_for(Views::Child, c) } }

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

    moved_child_ref = update_hash_for(Views::Child, moved_child)

    view = { '_type'    => 'Parent',
             'name'     => 'new_p',
             'children' => [moved_child_ref,
                            { '_type' => 'Child', 'name' => 'new' }] }

    deserialize_context = Views::ApplicationBase::DeserializeContext.new

    new_parent_view = Views::Parent.deserialize_from_view(view, deserialize_context: deserialize_context)

    new_parent = new_parent_view.model
    new_parent.reload

    assert_equal({ [Views::Parent, nil]           => 1,
                   [Views::Child,  nil]           => 1,
                   [Views::Child,  moved_child.id]=> 1,
                   [Views::Parent, @parent1.id]   => 1 },
                 count_all(deserialize_context.edit_checks))

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
            'children' => old_children.map { |x| update_hash_for(Views::Child, x) }}

    new_parent_model = Views::Parent.deserialize_from_view(view).model

    @parent1.reload
    new_parent_model.reload

    assert_equal([], @parent1.children)
    assert_equal(old_children,
                 new_parent_model.children.order(:position))
  end

  def test_implicit_release_invalid_has_many
    old_children = @parent1.children.order(:position)
    old_children_refs = old_children.map { |x| update_hash_for(Views::Child, x) }

    assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(
        [{ '_type'    => 'Parent',
           'name'     => 'newp',
           'children' => old_children_refs },
         update_hash_for(Views::Parent, @parent1) { |p1v| p1v['name'] = 'p1 new name' }])
    end
  end

  def test_move_child_to_existing
    old_children = @parent1.children.order(:position)
    moved_child = old_children[1]

    view = Views::Parent.new(@parent2).to_hash
    view['children'] << Views::Child.new(moved_child).to_hash

    retained_children = old_children - [moved_child]
    release_view = { '_type' => 'Parent', 'id' => @parent1.id,
                     'children' => retained_children.map { |c| update_hash_for(Views::Child, c) }}

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

  def test_has_many_append_child
    Views::Parent.new(@parent1).append_associated(:children, { "_type" => "Child", "name" => "new" })

    @parent1.reload

    assert_equal(4, @parent1.children.size)
    lc = @parent1.children.order(:position).last
    assert_equal("new", lc.name)
  end

  def test_has_many_insert_child
    skip("unimplemented")
  end

  def test_has_many_append_and_update_existing_association
    child = @parent1.children[1]

    cv = Views::Child.new(child).to_hash
    cv["name"] = "newname"

    Views::Parent.new(@parent1).append_associated(:children, cv)

    @parent1.reload

    # Child should have been moved to the end (and edited)
    assert_equal(3, @parent1.children.size)
    c1, c2, c3 = @parent1.children.order(:position)
    assert_equal("p1c1", c1.name)
    assert_equal("p1c3", c2.name)
    assert_equal(child, c3)
    assert_equal("newname", c3.name)

  end

  def test_has_many_move_existing_association
    p1c2 = @parent1.children[1]
    assert_equal(2, p1c2.position)

    Views::Parent.new(@parent2).append_associated("children", { "_type" => "Child", "id" => p1c2.id })

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

  def test_has_many_remove_existing_association
    child = @parent1.children[1]

    cv = Views::Child.new(child)

    Views::Parent.new(@parent1).delete_associated(:children, cv)

    @parent1.reload

    # Child should have been moved to the end (and edited)
    assert_equal(2, @parent1.children.size)
    c1, c2 = @parent1.children.order(:position)
    assert_equal("p1c1", c1.name)
    assert_equal("p1c3", c2.name)
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
end
