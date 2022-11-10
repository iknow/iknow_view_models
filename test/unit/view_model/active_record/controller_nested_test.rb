# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/unit'
require 'minitest/hooks'

require 'view_model'
require 'view_model/active_record'

require_relative '../../../helpers/controller_test_helpers'
require_relative '../../../helpers/callback_tracer'

class ViewModel::ActiveRecord::ControllerNestedTest < ActiveSupport::TestCase
  include ARVMTestUtilities
  include ControllerTestModels
  include ControllerTestControllers

  def before_all
    super

    build_controller_test_models(externalize: [:label, :child, :target])
  end

  def setup
    super
    @parent = make_parent
    @parent_view = ParentView.new(@parent)

    enable_logging!
  end

  #### Controller for nested model

  def test_nested_collection_index_associated
    _distractor = Parent.create(name: 'p2', children: [Child.new(name: 'c3', position: 1)])

    childcontroller = ChildController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'children',
      parent_id:        @parent.id
    })
    childcontroller.invoke(:index_associated)

    assert_equal(200, childcontroller.status)

    expected_children = @parent.children
    assert_equal({ 'data' => expected_children.map { |c| ChildView.new(c).serialize_to_hash } },
      childcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  def test_nested_collection_index
    distractor = Parent.create(name: 'p2', children: [Child.new(name: 'c3', position: 1)])
    childcontroller = ChildController.new

    childcontroller.invoke(:index)

    assert_equal(200, childcontroller.status)

    expected_children = @parent.children + distractor.children
    assert_equal({ 'data' => expected_children.map { |c| ChildView.new(c).serialize_to_hash } },
      childcontroller.hash_response)
  end

  def test_nested_collection_append_one
    data = { '_type' => 'Child', 'name' => 'c3' }
    childcontroller = ChildController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'children',
      parent_id:        @parent.id,
      data:             data,
    })

    childcontroller.invoke(:append)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(%w[c1 c2 c3], @parent.children.order(:position).pluck(:name))
    assert_equal({ 'data' => ChildView.new(@parent.children.last).serialize_to_hash },
      childcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  def test_nested_collection_append_many
    data = [{ '_type' => 'Child', 'name' => 'c3' },
      { '_type' => 'Child', 'name' => 'c4' },]

    childcontroller = ChildController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'children',
      parent_id: @parent.id,
      data: data,
    })
    childcontroller.invoke(:append)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(%w[c1 c2 c3 c4], @parent.children.order(:position).pluck(:name))
    new_children_hashes = @parent.children.last(2).map { |c| ChildView.new(c).serialize_to_hash }
    assert_equal({ 'data' => new_children_hashes },
      childcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  # FIXME: nested controllers really need to be to other roots; children aren't roots.
  def test_nested_collection_replace
    # Parent.children
    old_children = @parent.children

    data = [{ '_type' => 'Child', 'name' => 'newc1' },
      { '_type' => 'Child', 'name' => 'newc2' },]

    childcontroller = ChildController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'children',
      parent_id:        @parent.id,
      data:             data,
    })
    childcontroller.invoke(:replace)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(%w[newc1 newc2], @parent.children.order(:position).pluck(:name))
    assert_predicate(Child.where(id: old_children.map(&:id)), :empty?)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  def test_nested_collection_replace_bad_data
    data = [{ 'name' => 'nc' }]
    childcontroller = ChildController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'children',
      parent_id: @parent.id,
      data: data,
    })

    childcontroller.invoke(:replace)

    assert_equal(400, childcontroller.status)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  def test_nested_collection_replace_bulk
    other_parent = make_parent(name: 'p_other', child_names: ['other_c1', 'other_c2'])

    old_children = other_parent.children + @parent.children

    data = {
      '_type' => '_bulk_update',
      'updates' => [
        {
          'id' => @parent.id,
          'update' => [
            { '_type' => 'Child', 'name' => 'newc1' },
            { '_type' => 'Child', 'name' => 'newc2' },],
        },
        {
          'id' => other_parent.id,
          'update' => [
            { '_type' => 'Child', 'name' => 'other_newc1' },
            { '_type' => 'Child', 'name' => 'other_newc2' },],
        }
      ],
    }

    childcontroller = ChildController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'children',
      data:             data,
    })

    childcontroller.invoke(:replace_bulk)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload
    other_parent.reload

    assert_equal(%w[newc1 newc2], @parent.children.order(:position).pluck(:name))
    assert_equal(%w[other_newc1 other_newc2], other_parent.children.order(:position).pluck(:name))

    assert_predicate(Child.where(id: old_children.map(&:id)), :empty?)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end


  def test_nested_collection_disassociate_one
    old_child = @parent.children.first
    childcontroller = ChildController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'children',
      parent_id:        @parent.id,
      id:               old_child.id,
    })
    childcontroller.invoke(:disassociate)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(%w[c2], @parent.children.order(:position).pluck(:name))
    assert_predicate(Child.where(id: old_child.id), :empty?)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  def test_nested_collection_disassociate_many
    old_children = @parent.children

    childcontroller = ChildController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'children',
      parent_id:        @parent.id,
    })
    childcontroller.invoke(:disassociate_all)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_predicate(@parent.children, :empty?)
    assert_predicate(Child.where(id: old_children.map(&:id)), :empty?)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  # direct methods on nested controller
  def test_nested_collection_destroy
    old_child = @parent.children.first
    childcontroller = ChildController.new(params: { id: old_child.id })
    childcontroller.invoke(:destroy)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(%w[c2], @parent.children.order(:position).pluck(:name))
    assert_predicate(Child.where(id: old_child.id), :empty?)
  end

  def test_nested_collection_update
    old_child = @parent.children.first

    data = { 'id' => old_child.id,
      '_type' => 'Child',
      'name' => 'new_name' }

    childcontroller = ChildController.new(params: { data: data })
    childcontroller.invoke(:create)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    old_child.reload

    assert_equal('new_name', old_child.name)
    assert_equal({ 'data' => ChildView.new(old_child).serialize_to_hash },
      childcontroller.hash_response)
  end

  def test_nested_collection_show
    old_child = @parent.children.first

    childcontroller = ChildController.new(params: { id: old_child.id })
    childcontroller.invoke(:show)

    assert_equal({ 'data' => ChildView.new(old_child).serialize_to_hash },
      childcontroller.hash_response)

    assert_equal(200, childcontroller.status)
  end

  ## Single association

  def test_nested_singular_replace_from_parent
    old_label = @parent.label

    data = { '_type' => 'Label', 'text' => 'new label' }
    labelcontroller = LabelController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'label',
      parent_id:        @parent.id,
      data:             data,
    })
    labelcontroller.invoke(:create_associated)

    assert_equal(200, labelcontroller.status, labelcontroller.hash_response)

    @parent.reload

    assert_equal({ 'data' => { '_type'    => 'Label',
      '_version' => 1,
      'id'       => @parent.label.id,
      'text'     => 'new label' } },
      labelcontroller.hash_response)

    refute_equal(old_label, @parent.label)
    assert_equal('new label', @parent.label.text)

    assert_all_hooks_nested_inside_parent_hook(labelcontroller.hook_trace)
  end

  def test_nested_singular_show_from_parent
    old_label = @parent.label

    labelcontroller = LabelController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'label',
      parent_id:        @parent.id,
    })
    labelcontroller.invoke(:show_associated)

    assert_equal(200, labelcontroller.status, labelcontroller.hash_response)

    assert_equal({ 'data' => LabelView.new(old_label).serialize_to_hash },
      labelcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(labelcontroller.hook_trace)
  end

  def test_nested_singular_destroy_from_parent
    old_target = @parent.target

    targetcontroller = TargetController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'target',
      parent_id:        @parent.id,
    })
    targetcontroller.invoke(:destroy_associated)

    @parent.reload

    assert_equal(200, targetcontroller.status, targetcontroller.hash_response)
    assert_equal({ 'data' => nil }, targetcontroller.hash_response)

    assert_nil(@parent.target)
    assert_predicate(Target.where(id: old_target.id), :empty?)

    assert_all_hooks_nested_inside_parent_hook(targetcontroller.hook_trace)
  end

  def test_nested_singular_update_from_parent
    old_label = @parent.label

    data = { '_type' => 'Label', 'id' => old_label.id, 'text' => 'new label' }
    labelcontroller = LabelController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'label',
      parent_id:        @parent.id,
      data:             data,
    })
    labelcontroller.invoke(:create_associated)

    assert_equal(200, labelcontroller.status, labelcontroller.hash_response)

    old_label.reload

    assert_equal('new label', old_label.text)
    assert_equal({ 'data' => LabelView.new(old_label).serialize_to_hash },
      labelcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(labelcontroller.hook_trace)
  end

  def test_nested_singular_show_from_id
    old_label = @parent.label

    labelcontroller = LabelController.new(params: { id: old_label.id })
    labelcontroller.invoke(:show)

    assert_equal(200, labelcontroller.status, labelcontroller.hash_response)

    assert_equal({ 'data' => LabelView.new(old_label).serialize_to_hash },
      labelcontroller.hash_response)
  end

  def test_nested_singular_destroy_from_id
    # can't directly destroy pointed-to label that's referenced from parent:
    # foreign key violation. Destroy target instead.
    old_target = @parent.target

    targetcontroller = TargetController.new(params: { id: old_target.id })
    targetcontroller.invoke(:destroy)

    @parent.reload

    assert_equal(200, targetcontroller.status, targetcontroller.hash_response)
    assert_equal({ 'data' => nil }, targetcontroller.hash_response)

    assert_nil(@parent.target)
    assert_predicate(Target.where(id: old_target.id), :empty?)
  end

  def test_nested_singular_update
    old_label = @parent.label

    data = { '_type' => 'Label', 'id' => old_label.id, 'text' => 'new label' }
    labelcontroller = LabelController.new(params: { data: data })
    labelcontroller.invoke(:create)

    assert_equal(200, labelcontroller.status, labelcontroller.hash_response)

    old_label.reload

    assert_equal('new label', old_label.text)
    assert_equal({ 'data' => LabelView.new(old_label).serialize_to_hash },
      labelcontroller.hash_response)
  end

  def test_nested_singular_replace_bulk
    other_parent = make_parent(name: 'p_other', child_names: ['other_c1', 'other_c2'])

    target       = @parent.target
    other_target = other_parent.target

    data = {
      '_type'   => '_bulk_update',
      'updates' => [
        {
          'id'     => @parent.id,
          'update' => {
            '_type' => 'Target',
            'id'    => @parent.target.id,
            'text'  => 'parent, new target text'
          }
        },
        {
          'id'     => other_parent.id,
          'update' => {
            '_type' => 'Target',
            'id'    => other_parent.target.id,
            'text'  => 'other parent, new target text'
          }
        }
      ],
    }

    targetcontroller = TargetController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'target',
      data:             data,
    })

    targetcontroller.invoke(:create_associated_bulk)

    assert_equal(200, targetcontroller.status, targetcontroller.hash_response)

    target.reload
    other_target.reload

    assert_equal('parent, new target text', target.text)
    assert_equal('other parent, new target text', other_target.text)

    response = targetcontroller.hash_response
    response['data']['updates'].sort_by! { |x| x.fetch('id') }

    assert_equal(
      {
        'data' => {
          '_type' => '_bulk_update',
          'updates' => [
            {
              'id'     => @parent.id,
              'update' => TargetView.new(target).serialize_to_hash,
            },
            {
              'id'     => other_parent.id,
              'update' => TargetView.new(other_target).serialize_to_hash,
            },
          ].sort_by { |x| x.fetch('id') }
        }
      },
      response,
    )
  end

  # Singular shared

  def test_nested_shared_singular_replace_bulk
    data = {
      '_type' => '_bulk_update',
      'updates' => [
        {
          'id' => @parent.id,
          'update' => { '_ref' => 'new_cat' },
        }
      ]
    }

    references = {
      'new_cat' => {
        '_type' => 'Category',
        '_new' => true,
        'name' => 'cat name'
      }
    }

    category_controller = CategoryController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'category',
      data:             data,
      references:       references,
    })

    category_controller.invoke(:replace_bulk)

    response = category_controller.hash_response

    data, references = response.values_at('data', 'references')
    ref_key = references.keys.first

    assert_equal(
      {
        '_type'   => '_bulk_update',
        'updates' => [{
          'id'     => @parent.id,
          'update' => { '_ref' => ref_key }
        }],
      },
      data,
    )

    @parent.reload

    assert_equal(
      {
        ref_key => CategoryView.new(@parent.category).serialize_to_hash,
      },
      references,
    )
  end

  # Collection shared

  def test_nested_shared_collection_replace_bulk
    data = {
      '_type' => '_bulk_update',
      'updates' => [
        {
          'id' => @parent.id,
          'update' => [{ '_ref' => 'new_tag' }],
        }
      ]
    }

    references = {
      'new_tag' => {
        '_type' => 'Tag',
        '_new' => true,
        'name' => 'tag name'
      }
    }

    tags_controller = TagController.new(params: {
      owner_viewmodel:  'parent',
      association_name: 'tags',
      data:             data,
      references:       references,
    })

    tags_controller.invoke(:replace_bulk)

    response = tags_controller.hash_response

    data, references = response.values_at('data', 'references')
    ref_key = references.keys.first

    assert_equal(
      {
        '_type'   => '_bulk_update',
        'updates' => [{
          'id'     => @parent.id,
          'update' => [{ '_ref' => ref_key }]
        }],
      },
      data,
    )

    @parent.reload

    assert_equal(
      {
        ref_key => TagView.new(@parent.parent_tags.first.tag).serialize_to_hash,
      },
      references,
    )
  end
end
