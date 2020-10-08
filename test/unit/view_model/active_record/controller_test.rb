# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/unit'
require 'minitest/hooks'

require 'view_model'
require 'view_model/active_record'

require_relative '../../../helpers/controller_test_helpers'
require_relative '../../../helpers/callback_tracer'

class ViewModel::ActiveRecord::ControllerTest < ActiveSupport::TestCase
  include ARVMTestUtilities
  include ControllerTestModels
  include ControllerTestControllers

  def visit(hook, view)
    CallbackTracer::Visit.new(hook, view)
  end

  def each_hook_span(trace)
    return enum_for(:each_hook_span, trace) unless block_given?

    hook_nesting = []

    trace.each_with_index do |t, i|
      case t.hook
      when ViewModel::Callbacks::Hook::OnChange,
           ViewModel::Callbacks::Hook::BeforeValidate
        # ignore
      when ViewModel::Callbacks::Hook::BeforeVisit,
           ViewModel::Callbacks::Hook::BeforeDeserialize
        hook_nesting.push([t, i])

      when ViewModel::Callbacks::Hook::AfterVisit,
           ViewModel::Callbacks::Hook::AfterDeserialize
        (nested_top, nested_index) = hook_nesting.pop

        unless nested_top.hook.name == t.hook.name.sub(/^After/, 'Before')
          raise "Invalid nesting, processing '#{t.hook.name}', expected matching '#{nested_top.hook.name}'"
        end

        unless nested_top.view == t.view
          raise "Invalid nesting, processing '#{t.hook.name}', " \
                  "expected viewmodel '#{t.view}' to match '#{nested_top.view}'"
        end

        yield t.view, (nested_index..i), t.hook.name.sub(/^After/, '')

      else
        raise 'Unexpected hook type'
      end
    end
  end

  def show_span(view, range, hook)
    "#{view.class.name}(#{view.id}) #{range} #{hook}"
  end

  def enclosing_hooks(spans, inner_range)
    spans.select do |_view, range, _hook|
      inner_range != range && range.cover?(inner_range.min) && range.cover?(inner_range.max)
    end
  end

  def assert_all_hooks_nested_inside_parent_hook(trace)
    spans = each_hook_span(trace).to_a

    spans.reject { |view, _range, _hook| view.class == ParentView }.each do |view, range, hook|
      enclosing_spans = enclosing_hooks(spans, range)

      enclosing_parent_hook = enclosing_spans.detect do |other_view, _other_range, other_hook|
        other_hook == hook && other_view.class == ParentView
      end

      next if enclosing_parent_hook

      self_str      = show_span(view, range, hook)
      enclosing_str = enclosing_spans.map { |ov, ora, oh| show_span(ov, ora, oh) }.join("\n")
      assert_not_nil(
        enclosing_parent_hook,
        "Invalid nesting of hook: #{self_str}\nEnclosing hooks:\n#{enclosing_str}")
    end
  end

  def setup
    super
    @parent = Parent.create(name: 'p',
                            children: [Child.new(name: 'c1', position: 1.0),
                                       Child.new(name: 'c2', position: 2.0),],
                            label: Label.new,
                            target: Target.new)

    @parent_view = ParentView.new(@parent)

    enable_logging!
  end

  def test_show
    parentcontroller = ParentController.new(id: @parent.id)
    parentcontroller.invoke(:show)

    assert_equal({ 'data' => @parent_view.to_hash },
                 parentcontroller.hash_response)

    assert_equal(200, parentcontroller.status)

    assert_all_hooks_nested_inside_parent_hook(parentcontroller.hook_trace)
  end

  def test_migrated_show
    parentcontroller = ParentController.new(id: @parent.id, versions: { ParentView.view_name => 1 })
    parentcontroller.invoke(:show)

    expected_view = @parent_view.to_hash
                      .except('name')
                      .merge('old_name' => @parent.name,
                             ViewModel::VERSION_ATTRIBUTE => 1,
                             ViewModel::MIGRATED_ATTRIBUTE => true)

    assert_equal({ 'data' => expected_view },
                 parentcontroller.hash_response)

    assert_equal(200, parentcontroller.status)

    assert_all_hooks_nested_inside_parent_hook(parentcontroller.hook_trace)
  end

  def test_index
    p2      = Parent.create(name: 'p2')
    p2_view = ParentView.new(p2)

    parentcontroller = ParentController.new
    parentcontroller.invoke(:index)

    assert_equal(200, parentcontroller.status)

    assert_equal(parentcontroller.hash_response,
                 { 'data' => [@parent_view.to_hash, p2_view.to_hash] })

    assert_all_hooks_nested_inside_parent_hook(parentcontroller.hook_trace)
  end

  def test_create
    data = {
        '_type'    => 'Parent',
        'name'     => 'p2',
        'label'    => { '_type' => 'Label', 'text' => 'l' },
        'target'   => { '_type' => 'Target', 'text' => 't' },
        'children' => [{ '_type' => 'Child', 'name' => 'c1' },
                       { '_type' => 'Child', 'name' => 'c2' },],
    }

    parentcontroller = ParentController.new(data: data)
    parentcontroller.invoke(:create)

    assert_equal(200, parentcontroller.status)

    p2      = Parent.where(name: 'p2').first
    p2_view = ParentView.new(p2)
    assert(p2.present?, 'p2 created')

    assert_equal({ 'data' => p2_view.to_hash }, parentcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(parentcontroller.hook_trace)
  end

  def test_migrated_create
    data = {
      '_type'    => 'Parent',
      '_version' => 1,
      'old_name' => 'p2',
    }

    parentcontroller = ParentController.new(data: data, versions: { ParentView.view_name => 1 })
    parentcontroller.invoke(:create)

    assert_equal(200, parentcontroller.status)

    p2 = Parent.where(name: 'p2').first
    assert(p2.present?, 'p2 created')
  end

  def test_create_empty
    parentcontroller = ParentController.new(data: [])
    parentcontroller.invoke(:create)

    assert_equal(400, parentcontroller.status)
  end

  def test_create_invalid
    parentcontroller = ParentController.new(data: 42)
    parentcontroller.invoke(:create)

    assert_equal(400, parentcontroller.status)
  end

  def test_update
    data = { 'id'    => @parent.id,
             '_type' => 'Parent',
             'name'  => 'new' }

    parentcontroller = ParentController.new(id: @parent.id, data: data)
    parentcontroller.invoke(:create)

    assert_equal(200, parentcontroller.status)

    @parent.reload

    assert_equal('new', @parent.name)
    assert_equal({ 'data' => @parent_view.to_hash },
                 parentcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(parentcontroller.hook_trace)
  end

  def test_destroy
    parentcontroller = ParentController.new(id: @parent.id)
    parentcontroller.invoke(:destroy)

    assert_equal(200, parentcontroller.status)

    assert(Parent.where(id: @parent.id).blank?, "record doesn't exist after delete")

    assert_equal({ 'data' => nil },
                 parentcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(parentcontroller.hook_trace)
  end

  def test_show_missing
    parentcontroller = ParentController.new(id: 9999)
    parentcontroller.invoke(:show)

    assert_equal(404, parentcontroller.status)
    assert_equal({ 'error' => {
                     ViewModel::TYPE_ATTRIBUTE => ViewModel::ErrorView.view_name,
                     ViewModel::VERSION_ATTRIBUTE => ViewModel::ErrorView.schema_version,
                     'status' => 404,
                     'detail' => "Couldn't find Parent(s) with id(s)=[9999]",
                     'title' => nil,
                     'code' => 'DeserializationError.NotFound',
                     'meta' => { 'nodes' => [{ '_type' => 'Parent', 'id' => 9999 }] },
                     'exception' => nil,
                     'causes' => nil } },
                 parentcontroller.hash_response)
  end

  def test_create_invalid_shallow_validation
    data = { '_type'    => 'Parent',
             'children' => [{ '_type' => 'Child',
                              'age'   => 42 }] }

    parentcontroller = ParentController.new(data: data)
    parentcontroller.invoke(:create)

    assert_equal({ 'error' => {
                     ViewModel::TYPE_ATTRIBUTE => ViewModel::ErrorView.view_name,
                     ViewModel::VERSION_ATTRIBUTE => ViewModel::ErrorView.schema_version,
                     'status' => 400,
                     'detail' => 'Validation failed: \'age\' must be less than 42',
                     'title' => nil,
                     'code' => 'DeserializationError.Validation',
                     'meta' => { 'nodes' => [{ '_type' => 'Child', 'id' => nil }],
                                 'attribute' => 'age',
                                 'message' => 'must be less than 42',
                                 'details' => { 'error' => 'less_than', 'value' => 42, 'count' => 42 } },
                     'exception' => nil,
                     'causes' => nil } },
                 parentcontroller.hash_response)
  end

  def test_create_invalid_shallow_constraint
    data = { '_type'    => 'Parent',
             'children' => [{ '_type' => 'Child',
                              'age'   => 1 }] }
    parentcontroller = ParentController.new(data: data)
    parentcontroller.invoke(:create)

    assert_equal(400, parentcontroller.status)
    assert_match(/check constraint/i,
                 parentcontroller.hash_response['error']['detail'],
                 'Database error propagated')
  end

  def test_destroy_missing
    parentcontroller = ParentController.new(id: 9999)
    parentcontroller.invoke(:destroy)

    assert_equal({ 'error' => {
                     ViewModel::TYPE_ATTRIBUTE => ViewModel::ErrorView.view_name,
                     ViewModel::VERSION_ATTRIBUTE => ViewModel::ErrorView.schema_version,
                     'status' => 404,
                     'detail' => "Couldn't find Parent(s) with id(s)=[9999]",
                     'title' => nil,
                     'code' => 'DeserializationError.NotFound',
                     'meta' => { 'nodes' => [{ '_type' => 'Parent', 'id' => 9999 }] },
                     'exception' => nil,
                     'causes' => nil } },
                 parentcontroller.hash_response)
    assert_equal(404, parentcontroller.status)
  end

  #### Controller for nested model

  def test_nested_collection_index_associated
    _distractor = Parent.create(name: 'p2', children: [Child.new(name: 'c3', position: 1)])

    childcontroller = ChildController.new(parent_id: @parent.id)
    childcontroller.invoke(:index_associated)

    assert_equal(200, childcontroller.status)

    expected_children = @parent.children
    assert_equal({ 'data' => expected_children.map { |c| ChildView.new(c).to_hash } },
                 childcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  def test_nested_collection_index
    distractor = Parent.create(name: 'p2', children: [Child.new(name: 'c3', position: 1)])
    childcontroller = ChildController.new

    childcontroller.invoke(:index)

    assert_equal(200, childcontroller.status)

    expected_children = @parent.children + distractor.children
    assert_equal({ 'data' => expected_children.map { |c| ChildView.new(c).to_hash } },
                 childcontroller.hash_response)
  end

  def test_nested_collection_append_one
    data = { '_type' => 'Child', 'name' => 'c3' }
    childcontroller = ChildController.new(parent_id: @parent.id, data: data)

    childcontroller.invoke(:append)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(%w[c1 c2 c3], @parent.children.order(:position).pluck(:name))
    assert_equal({ 'data' => ChildView.new(@parent.children.last).to_hash },
                 childcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  def test_nested_collection_append_many
    data = [{ '_type' => 'Child', 'name' => 'c3' },
            { '_type' => 'Child', 'name' => 'c4' },]

    childcontroller = ChildController.new(parent_id: @parent.id, data: data)
    childcontroller.invoke(:append)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(%w[c1 c2 c3 c4], @parent.children.order(:position).pluck(:name))
    new_children_hashes = @parent.children.last(2).map { |c| ChildView.new(c).to_hash }
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

    childcontroller = ChildController.new(parent_id: @parent.id, data: data)
    childcontroller.invoke(:replace)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(%w[newc1 newc2], @parent.children.order(:position).pluck(:name))
    assert_predicate(Child.where(id: old_children.map(&:id)), :empty?)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  def test_nested_collection_replace_bad_data
    data = [{ 'name' => 'nc' }]
    childcontroller = ChildController.new(parent_id: @parent.id, data: data)

    childcontroller.invoke(:replace)

    assert_equal(400, childcontroller.status)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  def test_nested_collection_disassociate_one
    old_child = @parent.children.first
    childcontroller = ChildController.new(parent_id: @parent.id, id: old_child.id)
    childcontroller.invoke(:disassociate)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(%w[c2], @parent.children.order(:position).pluck(:name))
    assert_predicate(Child.where(id: old_child.id), :empty?)

    assert_all_hooks_nested_inside_parent_hook(childcontroller.hook_trace)
  end

  def test_nested_collection_disassociate_many
    old_children = @parent.children

    childcontroller = ChildController.new(parent_id: @parent.id)
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
    childcontroller = ChildController.new(id: old_child.id)
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

    childcontroller = ChildController.new(data: data)
    childcontroller.invoke(:create)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    old_child.reload

    assert_equal('new_name', old_child.name)
    assert_equal({ 'data' => ChildView.new(old_child).to_hash },
                 childcontroller.hash_response)
  end

  def test_nested_collection_show
    old_child = @parent.children.first

    childcontroller = ChildController.new(id: old_child.id)
    childcontroller.invoke(:show)

    assert_equal({ 'data' => ChildView.new(old_child).to_hash },
                 childcontroller.hash_response)

    assert_equal(200, childcontroller.status)
  end

  ## Single association

  def test_nested_singular_replace_from_parent
    old_label = @parent.label

    data = { '_type' => 'Label', 'text' => 'new label' }
    labelcontroller = LabelController.new(parent_id: @parent.id, data: data)
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

    labelcontroller = LabelController.new(parent_id: @parent.id)
    labelcontroller.invoke(:show_associated)

    assert_equal(200, labelcontroller.status, labelcontroller.hash_response)

    assert_equal({ 'data' => LabelView.new(old_label).to_hash },
                 labelcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(labelcontroller.hook_trace)
  end

  def test_nested_singular_destroy_from_parent
    old_label = @parent.label

    labelcontroller = LabelController.new(parent_id: @parent.id)
    labelcontroller.invoke(:destroy_associated)

    @parent.reload

    assert_equal(200, labelcontroller.status, labelcontroller.hash_response)
    assert_equal({ 'data' => nil }, labelcontroller.hash_response)

    assert_nil(@parent.label)
    assert_predicate(Label.where(id: old_label.id), :empty?)

    assert_all_hooks_nested_inside_parent_hook(labelcontroller.hook_trace)
  end

  def test_nested_singular_update_from_parent
    old_label = @parent.label

    data = { '_type' => 'Label', 'id' => old_label.id, 'text' => 'new label' }
    labelcontroller = LabelController.new(parent_id: @parent.id, data: data)
    labelcontroller.invoke(:create_associated)

    assert_equal(200, labelcontroller.status, labelcontroller.hash_response)

    old_label.reload

    assert_equal('new label', old_label.text)
    assert_equal({ 'data' => LabelView.new(old_label).to_hash },
                 labelcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(labelcontroller.hook_trace)
  end

  def test_nested_singular_show_from_id
    old_label = @parent.label

    labelcontroller = LabelController.new(id: old_label.id)
    labelcontroller.invoke(:show)

    assert_equal(200, labelcontroller.status, labelcontroller.hash_response)

    assert_equal({ 'data' => LabelView.new(old_label).to_hash },
                 labelcontroller.hash_response)
  end

  def test_nested_singular_destroy_from_id
    # can't directly destroy pointed-to label that's referenced from parent:
    # foreign key violation. Destroy target instead.
    old_target = @parent.target

    targetcontroller = TargetController.new(id: old_target.id)
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
    labelcontroller = LabelController.new(data: data)
    labelcontroller.invoke(:create)

    assert_equal(200, labelcontroller.status, labelcontroller.hash_response)

    old_label.reload

    assert_equal('new label', old_label.text)
    assert_equal({ 'data' => LabelView.new(old_label).to_hash },
                 labelcontroller.hash_response)
  end
end
