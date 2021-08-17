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

  def before_all
    super

    build_controller_test_models
  end

  def visit(hook, view)
    CallbackTracer::Visit.new(hook, view)
  end

  def setup
    super
    @parent = make_parent
    @parent_view = ParentView.new(@parent)

    enable_logging!
  end

  def test_show
    parentcontroller = ParentController.new(params: { id: @parent.id })
    parentcontroller.invoke(:show)

    assert_equal({ 'data' => @parent_view.to_hash },
                 parentcontroller.hash_response)

    assert_equal(200, parentcontroller.status)

    assert_all_hooks_nested_inside_parent_hook(parentcontroller.hook_trace)
  end

  def test_migrated_show
    parentcontroller = ParentController.new(
      params: { id: @parent.id },
      headers: { 'X-ViewModel-Versions' => { ParentView.view_name => 1 }.to_json })

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

  def test_invalid_migration_header
    parentcontroller = ParentController.new(
      params: { id: @parent.id },
      headers: { 'X-ViewModel-Versions' => 'not a json' })

    parentcontroller.invoke(:show)
    assert_equal(400, parentcontroller.status)
    assert_match(/Invalid JSON/i,
                 parentcontroller.hash_response['error']['detail'],
                 'json error propagated')
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

    parentcontroller = ParentController.new(params: { data: data })
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

    parentcontroller = ParentController.new(params: { data: data, versions: { ParentView.view_name => 1 } })
    parentcontroller.invoke(:create)

    assert_equal(200, parentcontroller.status)

    p2 = Parent.where(name: 'p2').first
    assert(p2.present?, 'p2 created')
  end

  def test_create_empty
    parentcontroller = ParentController.new(params: { data: [] })
    parentcontroller.invoke(:create)

    assert_equal(400, parentcontroller.status)
  end

  def test_create_invalid
    parentcontroller = ParentController.new(params: { data: 42 })
    parentcontroller.invoke(:create)

    assert_equal(400, parentcontroller.status)
  end

  def test_update
    data = { 'id'    => @parent.id,
             '_type' => 'Parent',
             'name'  => 'new' }

    parentcontroller = ParentController.new(params: { id: @parent.id, data: data })
    parentcontroller.invoke(:create)

    assert_equal(200, parentcontroller.status)

    @parent.reload

    assert_equal('new', @parent.name)
    assert_equal({ 'data' => @parent_view.to_hash },
                 parentcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(parentcontroller.hook_trace)
  end

  def test_destroy
    parentcontroller = ParentController.new(params: { id: @parent.id })
    parentcontroller.invoke(:destroy)

    assert_equal(200, parentcontroller.status)

    assert(Parent.where(id: @parent.id).blank?, "record doesn't exist after delete")

    assert_equal({ 'data' => nil },
                 parentcontroller.hash_response)

    assert_all_hooks_nested_inside_parent_hook(parentcontroller.hook_trace)
  end

  def test_show_missing
    parentcontroller = ParentController.new(params: { id: 9999 })
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

    parentcontroller = ParentController.new(params: { data: data })
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
    parentcontroller = ParentController.new(params: { data: data })
    parentcontroller.invoke(:create)

    assert_equal(400, parentcontroller.status)
    assert_match(/check constraint/i,
                 parentcontroller.hash_response['error']['detail'],
                 'Database error propagated')
  end

  def test_destroy_missing
    parentcontroller = ParentController.new(params: { id: 9999 })
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

end
