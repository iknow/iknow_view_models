# frozen_string_literal: true

require_relative '../../../helpers/arvm_test_utilities'
require_relative '../../../helpers/arvm_test_models'
require_relative '../../../helpers/viewmodel_spec_helpers'

require 'minitest/autorun'

require 'view_model/active_record'

class ViewModel::ActiveRecord::HasManyTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  extend Minitest::Spec::DSL
  include ViewModelSpecHelpers::ParentAndOrderedChildren

  def setup
    super

    @model1 = model_class.new(name: 'p1',
                          children: [child_model_class.new(name: 'p1c1', position: 1),
                                     child_model_class.new(name: 'p1c2', position: 2),
                                     child_model_class.new(name: 'p1c3', position: 3),])
    @model1.save!

    @model2 = model_class.new(name: 'p2',
                          children: [child_model_class.new(name: 'p2c1').tap { |c| c.position = 1 },
                                     child_model_class.new(name: 'p2c2').tap { |c| c.position = 2 },])

    @model2.save!

    enable_logging!
  end

  def test_load_associated
    parentview = viewmodel_class.new(@model1)

    childviews = parentview.load_associated(:children)
    assert_equal(3, childviews.size)
    assert_equal(['p1c1', 'p1c2', 'p1c3'],
                 childviews.map(&:name))
  end

  def test_serialize_view
    view, _refs = serialize_with_references(viewmodel_class.new(@model1))

    assert_equal({ '_type'    => 'Model',
                   '_version' => 1,
                   'id'       => @model1.id,
                   'name'     => @model1.name,
                   'children' => @model1.children.map { |child| { '_type' => 'Child',
                                                                   '_version' => 1,
                                                                   'id'       => child.id,
                                                                   'name'     => child.name } } },
                 view)
  end

  def test_loading_batching
    log_queries do
      serialize(viewmodel_class.load)
    end
    assert_equal(['Model Load', 'Child Load'],
                 logged_load_queries)
  end

  def test_create_from_view
    view = {
      '_type'    => 'Model',
      'name'     => 'p',
      'children' => [{ '_type' => 'Child', 'name' => 'c1' },
                     { '_type' => 'Child', 'name' => 'c2' },],
    }

    pv = viewmodel_class.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal('p', p.name)

    assert_equal(2, p.children.count)
    p.children.order(:id).each_with_index do |c, i|
      assert(!c.changed?)
      assert(!c.new_record?)
      assert_equal("c#{i + 1}", c.name)
    end
  end

  def test_editability_raises
    no_edit_context = viewmodel_class.new_deserialize_context(can_edit: false)

    assert_raises(ViewModel::AccessControlError) do
      # append child
      viewmodel_class.new(@model1).append_associated(:children, { '_type' => 'Child', 'name' => 'hi' }, deserialize_context: no_edit_context)
    end

    assert_raises(ViewModel::AccessControlError) do
      # destroy child
      viewmodel_class.new(@model1).delete_associated(:children, @model1.children.first.id, deserialize_context: no_edit_context)
    end
  end

  def test_create_has_many_empty
    view = { '_type' => 'Model', 'name' => 'p', 'children' => [] }
    pv = viewmodel_class.deserialize_from_view(view)
    assert(pv.model.children.blank?)
  end

  def test_create_has_many
    view = { '_type'    => 'Model',
             'name'     => 'p',
             'children' => [{ '_type' => 'Child', 'name' => 'c1' },
                            { '_type' => 'Child', 'name' => 'c2' },] }

    context = viewmodel_class.new_deserialize_context
    pv = viewmodel_class.deserialize_from_view(view, deserialize_context: context)

    assert_contains_exactly(
      [pv.to_reference, pv.children[0].to_reference, pv.children[1].to_reference],
      context.valid_edit_refs)

    assert_equal(%w[c1 c2], pv.model.children.map(&:name))
  end

  def test_nil_multiple_association
    view = {
      '_type' => 'Model',
      'children' => nil,
    }
    ex = assert_raises(ViewModel::DeserializationError::InvalidSyntax) do
      viewmodel_class.deserialize_from_view(view)
    end

    assert_match(/Invalid collection update value 'nil'/, ex.message)
  end

  def test_non_array_multiple_association
    view = {
      '_type' => 'Model',
      'children' => { '_type' => 'Child', 'name' => 'c1' },
    }
    ex = assert_raises(ViewModel::DeserializationError::InvalidSyntax) do
      viewmodel_class.deserialize_from_view(view)
    end

    assert_match(/Errors parsing collection functional update/, ex.message)
  end

  def test_replace_has_many
    old_children = @model1.children

    alter_by_view!(viewmodel_class, @model1) do |view, _refs|
      view['children'] = [{ '_type' => 'Child', 'name' => 'new_child' }]
    end

    assert_equal(['new_child'], @model1.children.map(&:name))
    assert_equal([], child_model_class.where(id: old_children.map(&:id)))
  end

  def test_replace_associated_has_many
    old_children = @model1.children

    pv = viewmodel_class.new(@model1)
    context = viewmodel_class.new_deserialize_context

    nc = pv.replace_associated(:children,
                               [{ '_type' => 'Child', 'name' => 'new_child' }],
                               deserialize_context: context)

    expected_edit_checks = [pv.to_reference,
                            *old_children.map { |x| ViewModel::Reference.new(child_viewmodel_class, x.id) },
                            *nc.map(&:to_reference),]

    assert_contains_exactly(expected_edit_checks,
                            context.valid_edit_refs)

    assert_equal(1, nc.size)
    assert_equal('new_child', nc[0].name)

    @model1.reload
    assert_equal(['new_child'], @model1.children.map(&:name))
    assert_equal([], child_model_class.where(id: old_children.map(&:id)))
  end

  def test_replace_associated_has_many_functional
    old_children = @model1.children

    pv = viewmodel_class.new(@model1)
    context = viewmodel_class.new_deserialize_context

    update = build_fupdate do
      append([{ '_type' => 'Child', 'name' => 'new_child' }])
      remove([{ '_type' => 'Child', 'id' => old_children.last.id }])
      update([{ '_type' => 'Child', 'id' => old_children.first.id, 'name' => 'renamed p1c1' }])
    end

    updated = pv.replace_associated(:children, update, deserialize_context: context)
    new_child = updated.detect { |c| c.name == 'new_child' }

    expected_edit_checks = [pv.to_reference,
                            ViewModel::Reference.new(child_viewmodel_class, new_child.id),
                            ViewModel::Reference.new(child_viewmodel_class, old_children.first.id),
                            ViewModel::Reference.new(child_viewmodel_class, old_children.last.id),]

    assert_contains_exactly(expected_edit_checks,
                            context.valid_edit_refs)

    assert_equal(2, updated.size)
    assert_contains_exactly(
      ['renamed p1c1', 'new_child'],
      updated.map(&:name),
    )

    @model1.reload
    assert_equal(['renamed p1c1', 'p1c2', 'new_child'], @model1.children.order(:position).map(&:name))
    assert_equal([], child_model_class.where(id: old_children.last.id))
  end

  def test_remove_has_many
    old_children = @model1.children
    _, context = alter_by_view!(viewmodel_class, @model1) do |view, _refs|
      view['children'] = []
    end

    expected_edit_checks = [ViewModel::Reference.new(viewmodel_class, @model1.id)] +
                           old_children.map { |x| ViewModel::Reference.new(child_viewmodel_class, x.id) }

    assert_equal(Set.new(expected_edit_checks),
                 context.valid_edit_refs.to_set)

    assert_equal([], @model1.children, 'no children associated with parent1')
    assert(child_model_class.where(id: old_children.map(&:id)).blank?, 'all children deleted')
  end

  def test_delete_associated_has_many
    c1, c2, c3 = @model1.children.order(:position).to_a

    pv = viewmodel_class.new(@model1)
    context = viewmodel_class.new_deserialize_context

    pv.delete_associated(:children, c1.id,
                         deserialize_context: context)

    expected_edit_checks = [ViewModel::Reference.new(viewmodel_class, @model1.id),
                            ViewModel::Reference.new(child_viewmodel_class, c1.id),].to_set

    assert_equal(expected_edit_checks,
                 context.valid_edit_refs.to_set)

    @model1.reload
    assert_equal([c2, c3], @model1.children.order(:position))
    assert(child_model_class.where(id: c1.id).blank?, 'old child deleted')
  end

  def test_edit_has_many
    c1, c2, c3 = @model1.children.order(:position).to_a

    pv, context = alter_by_view!(viewmodel_class, @model1) do |view, _refs|
      view['children'].shift
      view['children'] << { '_type' => 'Child', 'name' => 'new_c' }
    end
    nc = pv.children.detect { |c| c.name == 'new_c' }

    assert_contains_exactly(
      [ViewModel::Reference.new(viewmodel_class, @model1.id),
       ViewModel::Reference.new(child_viewmodel_class,  c1.id), # deleted child
       ViewModel::Reference.new(child_viewmodel_class,  nc.id),], # created child
      context.valid_edit_refs)

    assert_equal([c2, c3, child_model_class.find_by_name('new_c')],
                 @model1.children.order(:position))
    assert(child_model_class.where(id: c1.id).blank?)
  end

  def test_append_associated_move_has_many
    c1, c2, c3 = @model1.children.order(:position).to_a
    pv = viewmodel_class.new(@model1)

    # insert before
    pv.append_associated(:children,
                         { '_type' => 'Child', 'id' => c3.id },
                         before: ViewModel::Reference.new(child_viewmodel_class, c1.id),
                         deserialize_context: (context = viewmodel_class.new_deserialize_context))

    expected_edit_checks = [pv.to_reference]
    assert_contains_exactly(expected_edit_checks, context.valid_edit_refs)

    assert_equal([c3, c1, c2],
                 @model1.children.order(:position))

    # insert after
    pv.append_associated(:children,
                         { '_type' => 'Child', 'id' => c3.id },
                         after: ViewModel::Reference.new(child_viewmodel_class, c1.id),
                         deserialize_context: (context = viewmodel_class.new_deserialize_context))

    assert_contains_exactly(expected_edit_checks, context.valid_edit_refs)

    assert_equal([c1, c3, c2],
                 @model1.children.order(:position))

    # append
    pv.append_associated(:children,
                         { '_type' => 'Child', 'id' => c3.id },
                         deserialize_context: (context = viewmodel_class.new_deserialize_context))

    assert_contains_exactly(expected_edit_checks, context.valid_edit_refs)

    assert_equal([c1, c2, c3],
                 @model1.children.order(:position))

    # move from another parent
    p2c1 = @model2.children.order(:position).first

    pv.append_associated(:children,
                         { '_type' => 'Child', 'id' => p2c1.id },
                         deserialize_context: (context = viewmodel_class.new_deserialize_context))

    expected_edit_checks = [ViewModel::Reference.new(viewmodel_class, @model1.id),
                            ViewModel::Reference.new(viewmodel_class, @model2.id),]

    assert_contains_exactly(expected_edit_checks, context.valid_edit_refs)

    assert_equal([c1, c2, c3, p2c1],
                 @model1.children.order(:position))
  end

  def test_append_associated_insert_has_many
    c1, c2, c3 = @model1.children.order(:position).to_a
    pv = viewmodel_class.new(@model1)

    # insert before
    pv.append_associated(:children,
                         { '_type' => 'Child', 'name' => 'new1' },
                         before: ViewModel::Reference.new(child_viewmodel_class, c2.id),
                         deserialize_context: (context = viewmodel_class.new_deserialize_context))

    n1 = child_model_class.find_by_name('new1')

    expected_edit_checks = [ViewModel::Reference.new(viewmodel_class, @model1.id),
                            ViewModel::Reference.new(child_viewmodel_class, n1.id),]

    assert_contains_exactly(expected_edit_checks, context.valid_edit_refs)

    assert_equal([c1, n1, c2, c3],
                 @model1.children.order(:position))

    # insert after
    pv.append_associated(:children,
                         { '_type' => 'Child', 'name' => 'new2' },
                         after: ViewModel::Reference.new(child_viewmodel_class, c2.id),
                         deserialize_context: (context = viewmodel_class.new_deserialize_context))

    n2 = child_model_class.find_by_name('new2')

    expected_edit_checks = [ViewModel::Reference.new(viewmodel_class, @model1.id),
                            ViewModel::Reference.new(child_viewmodel_class, n2.id),]

    assert_contains_exactly(expected_edit_checks, context.valid_edit_refs)

    assert_equal([c1, n1, c2, n2, c3],
                 @model1.children.order(:position))

    # append
    pv.append_associated(:children,
                         { '_type' => 'Child', 'name' => 'new3' },
                         deserialize_context: (context = viewmodel_class.new_deserialize_context))

    n3 = child_model_class.find_by_name('new3')

    expected_edit_checks = [ViewModel::Reference.new(viewmodel_class, @model1.id),
                            ViewModel::Reference.new(child_viewmodel_class, n3.id),]

    assert_contains_exactly(expected_edit_checks, context.valid_edit_refs)

    assert_equal([c1, n1, c2, n2, c3, n3],
                 @model1.children.order(:position))
  end

  def test_edit_implicit_list_position
    c1, c2, c3 = @model1.children.order(:position).to_a

    alter_by_view!(viewmodel_class, @model1) do |view, _refs|
      view['children'].reverse!
      view['children'].insert(1, { '_type' => 'Child', 'name' => 'new_c' })
    end

    assert_equal([c3, child_model_class.find_by_name('new_c'), c2, c1],
                 @model1.children.order(:position))
  end

  def test_edit_missing_child
    view = {
      '_type' => 'Model',
      'children' => [{
                       '_type' => 'Child',
                       'id'    => 9999,
                     }],
    }

    ex = assert_raises(ViewModel::DeserializationError::NotFound) do
      viewmodel_class.deserialize_from_view(view)
    end

    assert_equal(ex.nodes, [ViewModel::Reference.new(child_viewmodel_class, 9999)])
  end

  def test_move_child_to_new
    old_children = @model1.children.order(:position)
    moved_child = old_children[1]

    moved_child_ref = update_hash_for(child_viewmodel_class, moved_child)

    view = { '_type'    => 'Model',
             'name'     => 'new_p',
             'children' => [moved_child_ref,
                            { '_type' => 'Child', 'name' => 'new' },] }

    retained_children = old_children - [moved_child]
    release_view = { '_type'    => 'Model',
                     'id'       => @model1.id,
                     'children' => retained_children.map { |c| update_hash_for(child_viewmodel_class, c) } }

    pv = viewmodel_class.deserialize_from_view([view, release_view])

    new_parent = pv.first.model
    new_parent.reload

    # child should be removed from old parent
    @model1.reload
    assert_equal(retained_children,
                 @model1.children.order(:position))

    # child should be added to new parent
    new_children = new_parent.children.order(:position)
    assert_equal(%w[p1c2 new], new_children.map(&:name))
    assert_equal(moved_child, new_children.first)
  end

  def test_has_many_cannot_take_from_outside_tree
    old_children = @model1.children.order(:position)

    assert_raises(ViewModel::DeserializationError::ParentNotFound) do
      alter_by_view!(viewmodel_class, @model2) do |p2, _refs|
        p2['children'] = old_children.map { |x| update_hash_for(child_viewmodel_class, x) }
      end
    end
  end

  def test_has_many_cannot_duplicate_unreleased_children
    assert_raises(ViewModel::DeserializationError::DuplicateNodes) do
      alter_by_view!(viewmodel_class, [@model1, @model2]) do |(p1, p2), _refs|
        p2['children'] = p1['children'].deep_dup
      end
    end
  end

  def test_has_many_cannot_duplicate_implicitly_unreleased_children
    assert_raises(ViewModel::DeserializationError::ParentNotFound) do
      alter_by_view!(viewmodel_class, [@model1, @model2]) do |(p1, p2), _refs|
        p2['children'] = p1['children']
        p1.delete('children')
      end
    end
  end

  def test_move_child_to_existing
    old_children = @model1.children.order(:position)
    moved_child = old_children[1]

    view = viewmodel_class.new(@model2).to_hash
    view['children'] << child_viewmodel_class.new(moved_child).to_hash

    retained_children = old_children - [moved_child]
    release_view = { '_type' => 'Model', 'id' => @model1.id,
                     'children' => retained_children.map { |c| update_hash_for(child_viewmodel_class, c) } }

    viewmodel_class.deserialize_from_view([view, release_view])

    @model1.reload
    @model2.reload

    # child should be removed from old parent and positions updated
    assert_equal(retained_children, @model1.children.order(:position))

    # child should be added to new parent with valid position
    new_children = @model2.children.order(:position)
    assert_equal(%w[p2c1 p2c2 p1c2], new_children.map(&:name))
    assert_equal(moved_child, new_children.last)
  end

  def test_has_many_append_child
    viewmodel_class.new(@model1).append_associated(:children, { '_type' => 'Child', 'name' => 'new' })

    @model1.reload

    assert_equal(4, @model1.children.size)
    lc = @model1.children.order(:position).last
    assert_equal('new', lc.name)
  end

  def test_has_many_append_and_update_existing_association
    child = @model1.children[1]

    cv = child_viewmodel_class.new(child).to_hash
    cv['name'] = 'newname'

    viewmodel_class.new(@model1).append_associated(:children, cv)

    @model1.reload

    # Child should have been moved to the end (and edited)
    assert_equal(3, @model1.children.size)
    c1, c2, c3 = @model1.children.order(:position)
    assert_equal('p1c1', c1.name)
    assert_equal('p1c3', c2.name)
    assert_equal(child, c3)
    assert_equal('newname', c3.name)
  end

  def test_has_many_move_existing_association
    p1c2 = @model1.children[1]
    assert_equal(2, p1c2.position)

    viewmodel_class.new(@model2).append_associated('children', { '_type' => 'Child', 'id' => p1c2.id })

    @model1.reload
    @model2.reload

    p1c = @model1.children.order(:position)
    assert_equal(2, p1c.size)
    assert_equal(['p1c1', 'p1c3'], p1c.map(&:name))

    p2c = @model2.children.order(:position)
    assert_equal(3, p2c.size)
    assert_equal(['p2c1', 'p2c2', 'p1c2'], p2c.map(&:name))
    assert_equal(p1c2, p2c[2])
    assert_equal(3, p2c[2].position)
  end

  def test_has_many_remove_existing_association
    child = @model1.children[1]

    viewmodel_class.new(@model1).delete_associated(:children, child.id)

    @model1.reload

    # Child should have been removed
    assert_equal(2, @model1.children.size)
    c1, c2 = @model1.children.order(:position)
    assert_equal('p1c1', c1.name)
    assert_equal('p1c3', c2.name)

    assert_equal(0, child_model_class.where(id: child.id).size)
  end

  def test_move_and_edit_child_to_new
    child = @model1.children[1]

    child_view = child_viewmodel_class.new(child).to_hash
    child_view['name'] = 'changed'

    view = { '_type' => 'Model',
             'name' => 'new_p',
             'children' => [child_view, { '_type' => 'Child', 'name' => 'new' }] }

    # TODO: this is as awkward here as it is in the application
    release_view = { '_type' => 'Model',
                     'id' => @model1.id,
                     'children' => [{ '_type' => 'Child', 'id' => @model1.children[0].id },
                                    { '_type' => 'Child', 'id' => @model1.children[2].id },] }

    pv = viewmodel_class.deserialize_from_view([view, release_view])
    new_parent = pv.first.model

    # child should be removed from old parent and positions updated
    @model1.reload
    assert_equal(2, @model1.children.size, 'database has 2 children')
    oc1, oc2 = @model1.children.order(:position)
    assert_equal('p1c1', oc1.name, 'database c1 unchanged')
    assert_equal('p1c3', oc2.name, 'database c2 unchanged')

    # child should be added to new parent with valid position
    assert_equal(2, new_parent.children.size, 'viewmodel has 2 children')
    nc1, nc2 = new_parent.children.order(:position)
    assert_equal(child, nc1)
    assert_equal('changed', nc1.name)
    assert_equal('new', nc2.name)
  end

  def test_move_and_edit_child_to_existing
    old_child = @model1.children[1]

    old_child_view = child_viewmodel_class.new(old_child).to_hash
    old_child_view['name'] = 'changed'
    view = viewmodel_class.new(@model2).to_hash
    view['children'] << old_child_view

    release_view = { '_type' => 'Model', 'id' => @model1.id,
                    'children' => [{ '_type' => 'Child', 'id' => @model1.children[0].id },
                                   { '_type' => 'Child', 'id' => @model1.children[2].id },] }

    viewmodel_class.deserialize_from_view([view, release_view])

    @model1.reload
    @model2.reload

    # child should be removed from old parent and positions updated
    assert_equal(2, @model1.children.size)
    oc1, oc2 = @model1.children.order(:position)

    assert_equal('p1c1', oc1.name)
    assert_equal('p1c3', oc2.name)

    # child should be added to new parent with valid position
    assert_equal(3, @model2.children.size)
    nc1, _, nc3 = @model2.children.order(:position)
    assert_equal('p2c1', nc1.name)

    assert_equal('p2c1', nc1.name)

    assert_equal(old_child, nc3)
    assert_equal('changed', nc3.name)
  end

  def test_functional_update_append
    children_before = @model1.children.order(:position).pluck(:id)
    fupdate = build_fupdate do
      append([{ '_type' => 'Child' },
              { '_type' => 'Child' },])
    end

    append_view = { '_type' => 'Model',
                        'id'       => @model1.id,
                        'children' => fupdate }

    result = viewmodel_class.deserialize_from_view(append_view)
    @model1.reload

    created_children = result.children[-2, 2].map(&:id)

    assert_equal(children_before + created_children,
                 @model1.children.order(:position).pluck(:id))
  end

  def test_functional_update_append_before_mid
    c1, c2, c3 = @model1.children.order(:position)

    fupdate = build_fupdate do
      append([{ '_type' => 'Child', 'name' => 'new c1' },
              { '_type' => 'Child', 'name' => 'new c2' },],
             before: { '_type' => 'Child', 'id' => c2.id })
    end

    append_view = { '_type'    => 'Model',
                    'id'       => @model1.id,
                    'children' => fupdate }
    viewmodel_class.deserialize_from_view(append_view)
    @model1.reload

    assert_equal([c1.name, 'new c1', 'new c2', c2.name, c3.name],
                 @model1.children.order(:position).pluck(:name))
  end

  def test_functional_update_append_before_reorder
    c1, c2, c3 = @model1.children.order(:position)

    fupdate = build_fupdate do
      append([{ '_type' => 'Child', 'id' => c3.id }],
             before: { '_type' => 'Child', 'id' => c2.id })
    end

    append_view = { '_type'    => 'Model',
                    'id'       => @model1.id,
                    'children' => fupdate }
    viewmodel_class.deserialize_from_view(append_view)
    @model1.reload

    assert_equal([c1.name, c3.name, c2.name],
                 @model1.children.order(:position).pluck(:name))
  end

  def test_functional_update_append_before_beginning
    c1, c2, c3 = @model1.children.order(:position)

    fupdate = build_fupdate do
      append([{ '_type' => 'Child', 'name' => 'new c1' },
              { '_type' => 'Child', 'name' => 'new c2' },],
             before: { '_type' => 'Child', 'id' => c1.id })
    end

    append_view = { '_type'    => 'Model',
                    'id'       => @model1.id,
                    'children' => fupdate }
    viewmodel_class.deserialize_from_view(append_view)
    @model1.reload

    assert_equal(['new c1', 'new c2', c1.name, c2.name, c3.name],
                 @model1.children.order(:position).pluck(:name))
  end

  def test_functional_update_append_before_corpse
    _, c2, _ = @model1.children.order(:position)
    c2.destroy

    fupdate = build_fupdate do
      append([{ '_type' => 'Child', 'name' => 'new c1' },
              { '_type' => 'Child', 'name' => 'new c2' },],
             before: { '_type' => 'Child', 'id' => c2.id })
    end

    append_view = { '_type'    => 'Model',
                    'id'       => @model1.id,
                    'children' => fupdate }
    assert_raises(ViewModel::DeserializationError::AssociatedNotFound) do
      viewmodel_class.deserialize_from_view(append_view)
    end
  end

  def test_functional_update_append_after_mid
    c1, c2, c3 = @model1.children.order(:position)

    fupdate = build_fupdate do
      append([{ '_type' => 'Child', 'name' => 'new c1' },
              { '_type' => 'Child', 'name' => 'new c2' },],
             after: { '_type' => 'Child', 'id' => c2.id })
    end

    append_view = { '_type'    => 'Model',
                    'id'       => @model1.id,
                    'children' => fupdate }
    viewmodel_class.deserialize_from_view(append_view)
    @model1.reload

    assert_equal([c1.name, c2.name, 'new c1', 'new c2', c3.name],
                 @model1.children.order(:position).pluck(:name))
  end

  def test_functional_update_append_after_end
    c1, c2, c3 = @model1.children.order(:position)

    fupdate = build_fupdate do
      append([{ '_type' => 'Child', 'name' => 'new c1' },
              { '_type' => 'Child', 'name' => 'new c2' },],
             after: { '_type' => 'Child', 'id' => c3.id })
    end

    append_view = { '_type'    => 'Model',
                    'id'       => @model1.id,
                    'children' => fupdate }
    viewmodel_class.deserialize_from_view(append_view)
    @model1.reload

    assert_equal([c1.name, c2.name, c3.name, 'new c1', 'new c2'],
                 @model1.children.order(:position).pluck(:name))
  end

  def test_functional_update_append_after_corpse
    _, c2, _ = @model1.children.order(:position)
    c2.destroy

    fupdate = build_fupdate do
      append([{ '_type' => 'Child', 'name' => 'new c1' },
              { '_type' => 'Child', 'name' => 'new c2' },],
             after: { '_type' => 'Child', 'id' => c2.id },
            )
    end

    append_view = { '_type'    => 'Model',
                    'id'       => @model1.id,
                    'children' => fupdate }
    assert_raises(ViewModel::DeserializationError::AssociatedNotFound) do
      viewmodel_class.deserialize_from_view(append_view)
    end
  end

  def test_functional_update_remove_success
    c1_id, c2_id, c3_id = @model1.children.pluck(:id)

    fupdate = build_fupdate do
      remove([{ '_type' => 'Child', 'id' => c2_id }])
    end

    remove_view = { '_type' => 'Model',
                            'id'       => @model1.id,
                            'children' => fupdate }
    viewmodel_class.deserialize_from_view(remove_view)
    @model1.reload

    assert_equal([c1_id, c3_id], @model1.children.pluck(:id))
  end

  def test_functional_update_remove_failure
    c_id = @model1.children.pluck(:id).first

    fupdate = build_fupdate do
      remove([{ '_type' => 'Child',
                'id'    => c_id,
                'name'  => 'remove and update disallowed' }])
    end

    remove_view = { '_type'    => 'Model',
                    'id'       => @model1.id,
                    'children' => fupdate }

    ex = assert_raises(ViewModel::DeserializationError::InvalidSyntax) do
      viewmodel_class.deserialize_from_view(remove_view)
    end

    assert_match(/Removed entities must have only _type and id fields/, ex.message)
  end

  def test_functional_update_move
    c1_id, c2_id, c3_id = @model1.children.pluck(:id)
    c4_id, c5_id = @model2.children.pluck(:id)

    remove_fupdate = build_fupdate do
      remove([{ '_type' => 'Child', 'id' => c2_id }])
    end

    append_fupdate = build_fupdate do
      append([{ '_type' => 'Child', 'id' => c2_id }])
    end

    move_view = [
      {
        '_type' => 'Model',
        'id'       => @model1.id,
        'children' => remove_fupdate
      },
      {
        '_type' => 'Model',
        'id'       => @model2.id,
        'children' => append_fupdate
      }
    ]

    viewmodel_class.deserialize_from_view(move_view)
    @model1.reload
    @model2.reload

    assert_equal([c1_id, c3_id], @model1.children.pluck(:id))
    assert_equal([c4_id, c5_id, c2_id], @model2.children.pluck(:id))
  end

  def test_functional_update_update_success
    c1_id, c2_id, c3_id = @model1.children.pluck(:id)

    fupdate = build_fupdate do
      update([{ '_type' => 'Child',
                'id'    => c2_id,
                'name'  => 'Functionally Updated Child' }])
    end

    update_view = { '_type' => 'Model',
                            'id'       => @model1.id,
                            'children' => fupdate }
    viewmodel_class.deserialize_from_view(update_view)
    @model1.reload

    assert_equal([c1_id, c2_id, c3_id], @model1.children.pluck(:id))
    assert_equal('Functionally Updated Child', child_model_class.find(c2_id).name)
  end

  def test_functional_update_update_failure
    cnew = child_model_class.create(model: model_class.create, position: 0).id

    fupdate = build_fupdate do
      update([{ '_type' => 'Child', 'id' => cnew }])
    end

    update_view = {
      '_type'    => 'Model',
      'id'       => @model1.id,
      'children' => fupdate,
    }

    assert_raises(ViewModel::DeserializationError::AssociatedNotFound) do
      viewmodel_class.deserialize_from_view(update_view)
    end
  end

  def test_functional_update_duplicate_refs
    child_id = @model1.children.pluck(:id).first

    fupdate = build_fupdate do
      # remove and append the same child
      remove([{ '_type' => 'Child', 'id' => child_id }])
      append([{ '_type' => 'Child', 'id' => child_id }])
    end

    update_view = { '_type'    => 'Model',
                    'id'       => @model1.id,
                    'children' => fupdate }

    ex = assert_raises(ViewModel::DeserializationError::InvalidStructure) do
      viewmodel_class.deserialize_from_view(update_view)
    end

    assert_match(/Duplicate functional update targets\b.*\bChild\b/, ex.message)
  end

  describe 'sti polymorphic children' do
    def setup
      child_viewmodel_class
      dog_viewmodel_class
      cat_viewmodel_class
      enable_logging!
    end

    def child_attributes
      super().merge(schema: ->(t) do
                      t.string :type, null: false
                      t.integer :dog_number
                      t.integer :cat_number
                    end)
    end

    def subject_association_features
      { viewmodels: [:Dog, :Cat] }
    end

    def dog_viewmodel_class
      @dog_viewmodel_class ||= define_viewmodel_class(:Dog, namespace: namespace, viewmodel_base: viewmodel_base, model_base: child_model_class) do
        define_model {}
        define_viewmodel do
          attribute :dog_number
          acts_as_list :position
        end
      end
    end

    def cat_viewmodel_class
      @cat_viewmodel_class ||= define_viewmodel_class(:Cat, namespace: namespace, viewmodel_base: viewmodel_base, model_base: child_model_class) do
        define_model {}
        define_viewmodel do
          attribute :cat_number
          acts_as_list :position
        end
      end
    end

    def new_model
      model_class.new(name: 'p', children: [Dog.new(position: 1, dog_number: 1), Cat.new(position: 2, cat_number: 2)])
    end

    it 'creates the model structure' do
      m = create_model!
      m.reload
      assert(m.is_a?(Model))
      children = m.children.order(:position)
      assert_equal(2, children.size)
      assert_kind_of(Dog, children[0])
      assert_kind_of(Cat, children[1])
    end

    it 'serializes' do
      model = create_model!
      view = serialize(ModelView.new(model))
      expected_view = {
        'id' => 1, '_type' => 'Model', '_version' => 1, 'name' => 'p',
        'children' => [
          { 'id' => 1, '_type' => 'Dog', '_version' => 1, 'dog_number' => 1 },
          { 'id' => 2, '_type' => 'Cat', '_version' => 1, 'cat_number' => 2 },
        ]
      }
      assert_equal(expected_view, view)
    end

    it 'creates from view' do
      view = {
        '_type' => 'Model',
        'name' => 'p',
        'children' => [
          { '_type' => 'Dog', 'dog_number' => 1 },
          { '_type' => 'Cat', 'cat_number' => 2 },
        ],
      }

      pv = ModelView.deserialize_from_view(view)
      p = pv.model

      assert(!p.changed?)
      assert(!p.new_record?)

      assert_equal('p', p.name)

      children = p.children.order(:position)

      assert_equal(2, children.size)
      assert_kind_of(Dog, children[0])
      assert_equal(1, children[0].dog_number)
      assert_kind_of(Cat, children[1])
      assert_equal(2, children[1].cat_number)
    end

    it 'updates with reordering' do
      model = create_model!

      alter_by_view!(ModelView, model) do |view, _refs|
        view['children'].reverse!
      end

      children = model.children.order(:position)
      assert_equal(2, children.size)
      assert_kind_of(Cat, children[0])
      assert_equal(2, children[0].cat_number)
      assert_kind_of(Dog, children[1])
      assert_equal(1, children[1].dog_number)
    end

    it 'functional updates' do
      model = create_model!

      alter_by_view!(ModelView, model) do |view, _refs|
        view['children'] = build_fupdate do
          append([{ '_type' => 'Cat', 'cat_number' => 100 }])
        end
      end

      assert_equal(3, model.children.size)
      new_child = model.children.order(:position).last
      assert_kind_of(Cat, new_child)
      assert_equal(100, new_child.cat_number)
    end

    it 'calculates eager_includes' do
      includes = viewmodel_class.eager_includes
      expected = DeepPreloader::Spec.new(
        'children' => DeepPreloader::PolymorphicSpec.new(
          {
            'Dog' => DeepPreloader::Spec.new,
            'Cat' => DeepPreloader::Spec.new,
          }))

      assert_equal(includes, expected)
    end
  end

  describe 'owned reference children' do
    def child_attributes
      super.merge(viewmodel: ->(_v) { root! })
    end

    def new_model
      new_children = (1 .. 2).map { |n| child_model_class.new(name: "c#{n}", position: n) }
      model_class.new(name: 'm1', children: new_children)
    end

    it 'makes a reference association' do
      assert(subject_association.referenced?)
    end

    it 'makes an owned association' do
      assert(subject_association.owned?)
    end

    it 'loads and batches' do
      create_model!

      log_queries do
        serialize(ModelView.load)
      end

      assert_equal(['Model Load', 'Child Load'], logged_load_queries)
    end

    it 'serializes' do
      model = create_model!
      view, refs = serialize_with_references(ModelView.new(model))

      children = model.children.sort_by(&:position)
      assert_equal(children.size, view['children'].size)

      child_refs = view['children'].map { |c| c['_ref'] }
      child_views = child_refs.map { |r| refs[r] }

      children.zip(child_views).each do |child, child_view|
        assert_equal(child_view,
                     { '_type'    => 'Child',
                       '_version' => 1,
                       'id'       => child.id,
                       'name'     => child.name })
      end

      assert_equal({ '_type'    => 'Model',
                     '_version' => 1,
                     'id'       => model.id,
                     'name'     => model.name,
                     'children' => view['children'] },
                   view)
    end

    it 'creates from view' do
      view = {
        '_type' => 'Model',
        'name'  => 'p',
        'children' => [{ '_ref' => 'r1' }],
      }

      refs = {
        'r1' => { '_type' => 'Child', 'name' => 'newkid' },
      }

      pv = ModelView.deserialize_from_view(view, references: refs)
      p = pv.model

      assert(!p.changed?)
      assert(!p.new_record?)

      assert_equal('p', p.name)

      assert(p.children.present?)
      assert_equal('newkid', p.children[0].name)
    end

    it 'updates with adding a child' do
      model = create_model!

      alter_by_view!(ModelView, model) do |view, refs|
        view['children'] << { '_ref' => 'ref1' }
        refs['ref1'] = {
          '_type' => 'Child',
          'name' => 'newchildname',
        }
      end

      assert_equal(3, model.children.size)
      assert_equal('newchildname', model.children.last.name)
    end

    it 'updates with adding a child functionally' do
      model = create_model!

      alter_by_view!(ModelView, model) do |view, refs|
        refs.clear

        view['children'] = build_fupdate do
          append([{ '_ref' => 'ref1' }])
        end

        refs['ref1'] = {
          '_type' => 'Child',
          'name' => 'newchildname',
        }
      end

      assert_equal(3, model.children.size)
      assert_equal('newchildname', model.children.last.name)
    end

    it 'updates with removing a child' do
      model = create_model!
      old_child = model.children.last

      alter_by_view!(ModelView, model) do |view, refs|
        removed = view['children'].pop['_ref']
        refs.delete(removed)
      end

      assert_equal(1, model.children.size)
      assert_equal('c1', model.children.first.name)
      assert_empty(child_model_class.where(id: old_child.id))
    end

    it 'updates with removing a child functionally' do
      model = create_model!
      old_child = model.children.last

      alter_by_view!(ModelView, model) do |view, refs|
        removed_ref = view['children'].pop['_ref']
        removed_id = refs[removed_ref]['id']
        refs.clear

        view['children'] = build_fupdate do
          remove([{ '_type' => 'Child', 'id' => removed_id }])
        end
      end

      assert_equal(1, model.children.size)
      assert_equal('c1', model.children.first.name)
      assert_empty(child_model_class.where(id: old_child.id))
    end

    it 'updates with replacing a child' do
      model = create_model!
      old_child = model.children.last

      alter_by_view!(ModelView, model) do |view, refs|
        exchange_ref = view['children'].last['_ref']
        refs[exchange_ref] = {
          '_type' => 'Child',
          'name' => 'newchildname',
        }
      end

      children = model.children.sort_by(&:position)
      assert_equal(2, children.size)
      refute_equal(old_child.id, children.last.id)
      assert_equal('newchildname', children.last.name)
      assert_empty(child_model_class.where(id: old_child.id))
    end

    it 'updates with replacing a child functionally' do
      model = create_model!
      old_child = model.children.first

      alter_by_view!(ModelView, model) do |view, refs|
        removed_ref = view['children'].shift['_ref']
        removed_id = refs[removed_ref]['id']
        refs.clear

        view['children'] = build_fupdate do
          append([{ '_ref' => 'repl_ref' }],
                 after: { '_type' => 'Child', 'id' => removed_id })
          remove([{ '_type' => 'Child', 'id' => removed_id }])
        end

        refs['repl_ref'] = {
          '_type' => 'Child',
          'name' => 'newchildname',
        }
      end

      children = model.children.sort_by(&:position)
      assert_equal(2, children.size)
      refute_equal(old_child.id, children.first.id)
      assert_equal('newchildname', children.first.name)
      assert_empty(child_model_class.where(id: old_child.id))
    end

    it 'updates with editing a child' do
      model = create_model!

      alter_by_view!(ModelView, model) do |view, refs|
        c1ref = view['children'].first['_ref']
        refs[c1ref]['name'] = 'renamed'
      end

      assert_equal(2, model.children.size)
      assert_equal('renamed', model.children.first.name)
    end

    it 'updates with editing a child functionally' do
      model = create_model!

      alter_by_view!(ModelView, model) do |view, refs|
        edit_ref = view['children'].shift['_ref']
        refs.slice!(edit_ref)

        view['children'] = build_fupdate do
          update([{ '_ref' => edit_ref }])
        end

        refs[edit_ref]['name'] = 'renamed'
      end

      assert_equal(2, model.children.size)
      assert_equal('renamed', model.children.first.name)
    end

    describe 'with association manipulation' do
      it 'appends a child' do
        view = create_viewmodel!

        view.append_associated(:children, { '_type' => 'Child', 'name' => 'newchildname' })

        view.model.reload
        assert_equal(3, view.children.size)
        assert_equal('newchildname', view.children.last.name)
      end

      it 'inserts a child' do
        view = create_viewmodel!
        c1 = view.children.first

        view.append_associated(:children,
                               { '_type' => 'Child', 'name' => 'newchildname' },
                               after: c1.to_reference)
        view.model.reload

        assert_equal(3, view.children.size)
        assert_equal('newchildname', view.children[1].name)
      end

      it 'moves a child' do
        view = create_viewmodel!
        c1, c2 = view.children

        view.append_associated(:children,
                               { '_type' => 'Child', 'id' => c2.id },
                               before: c1.to_reference)
        view.model.reload

        assert_equal(2, view.children.size)
        assert_equal(['c2', 'c1'], view.children.map(&:name))
      end

      it 'replaces children' do
        view = create_viewmodel!
        view.replace_associated(:children,
                                [{ '_type' => 'Child', 'name' => 'newchildname' }])

        view.model.reload

        assert_equal(1, view.children.size)
        assert_equal('newchildname', view.children[0].name)
      end

      it 'deletes a child' do
        view = create_viewmodel!
        view.delete_associated(:children, view.children.first.id)

        view.model.reload

        assert_equal(1, view.children.size)
        assert_equal('c2', view.children[0].name)
      end
    end
  end

  describe 'renaming associations' do
    def subject_association_features
      { as: :something_else }
    end

    def setup
      super

      @model = model_class.create(name: 'p1', children: [child_model_class.new(name: 'c1', position: 0)])

      enable_logging!
    end

    def test_dependencies
      root_updates, _ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes([{ '_type' => 'Model', 'something_else' => [] }])
      assert_equal(DeepPreloader::Spec.new('children' => DeepPreloader::Spec.new), root_updates.first.preload_dependencies)
    end

    def test_renamed_roundtrip
      alter_by_view!(viewmodel_class, @model) do |view, _refs|
        assert_equal([{ 'id'       => @model.children.first.id,
                        '_type'    => 'Child',
                        '_version' => 1,
                        'name'     => 'c1' }],
                     view['something_else'])

        view['something_else'][0]['name'] = 'new c1 name'
      end

      assert_equal('new c1 name', @model.children.first.name)
    end
  end
end
