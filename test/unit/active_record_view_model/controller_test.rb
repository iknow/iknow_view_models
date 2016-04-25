# -*- coding: utf-8 -*-

require "bundler/setup"
Bundler.require

require_relative "../../helpers/test_models.rb"

require 'byebug'

require "minitest/autorun"
require 'minitest/unit'

class ActiveRecordViewModel::ControllerTest < ActiveSupport::TestCase
  def setup
    @parent = Parent.create(name: "p",
                            children: [Child.new(name: "c1"), Child.new(name: "c2")])

    # Enable logging for the test
    ActiveRecord::Base.logger = Logger.new(STDOUT)
  end

  def teardown
    ActiveRecord::Base.logger = nil
  end

  def test_show
    parentcontroller = ParentController.new(id: @parent.id)
    parentcontroller.invoke(:show)

    assert_equal({ 'data' => Views::Parent.new(@parent).to_hash },
                 parentcontroller.hash_response)

    assert_equal(200, parentcontroller.status)
  end

  def test_index
    p2 = Parent.create(name: "p2")

    parentcontroller = ParentController.new
    parentcontroller.invoke(:index)

    assert_equal(200, parentcontroller.status)

    assert_equal(parentcontroller.hash_response,
                 { "data" => [Views::Parent.new(@parent).to_hash, Views::Parent.new(p2).to_hash] })
  end

  def test_create
    data = {
        '_type'    => 'Parent',
        'name'     => 'p2',
        'label'    => { '_type' => 'Label', 'text' => 'l' },
        'target'   => { '_type' => 'Target', 'text' => 't' },
        'children' => [{ '_type' => 'Child', 'name' => 'c1' },
                       { '_type' => 'Child', 'name' => 'c2' }]
    }

    parentcontroller = ParentController.new(data: data)
    parentcontroller.invoke(:create)

    assert_equal(200, parentcontroller.status)

    p = Parent.where(name: 'p2').first
    assert(p.present?, 'p created')

    assert_equal({ 'data' => Views::Parent.new(p).to_hash },
                 parentcontroller.hash_response)
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
    assert_equal({ 'data' => Views::Parent.new(@parent).to_hash },
                 parentcontroller.hash_response)
  end

  def test_destroy
    parentcontroller = ParentController.new(id: @parent.id)
    parentcontroller.invoke(:destroy)

    assert_equal(200, parentcontroller.status)

    assert(Parent.where(id: @parent.id).blank?, "record doesn't exist after delete")

    assert_equal({ 'data' => nil },
                 parentcontroller.hash_response)
  end

  def test_show_missing
    parentcontroller = ParentController.new(id: 9999)
    parentcontroller.invoke(:show)

    assert_equal(404, parentcontroller.status)
    assert_equal({ 'errors' => [{ 'status' => 404,
                                  'detail' => "Couldn't find Parent with 'id'=9999" }] },
                 parentcontroller.hash_response)
  end

  def test_create_invalid_shallow_validation
    data = { '_type'    => 'Parent',
             'children' => [{ '_type' => 'Child',
                              'age'   => 42 }] }

    parentcontroller = ParentController.new(data: data)
    parentcontroller.invoke(:create)

    assert_equal({ 'errors' => [{ 'status' => 500,
                                  'detail' => 'Validation failed: Age must be less than 42' }] },
                 parentcontroller.hash_response)
  end

  def test_create_invalid_shallow_constraint
    data = { '_type'    => 'Parent',
             'children' => [{ '_type' => 'Child',
                              'age'   => 1 }] }
    parentcontroller = ParentController.new(data: data)
    parentcontroller.invoke(:create)

    assert_equal(500, parentcontroller.status)
    assert_match(%r{check constraint}i,
                 parentcontroller.hash_response["errors"].first["detail"],
                 "Database error propagated")
  end

  def test_destroy_missing
    parentcontroller = ParentController.new(id: 9999)
    parentcontroller.invoke(:destroy)

    assert_equal({ 'errors' => [{ 'status' => 404,
                                  'detail' => "Couldn't find Parent with 'id'=9999" }] },
                 parentcontroller.hash_response)
    assert_equal(404, parentcontroller.status)
  end

  #### Controller for nested model

  def test_nested_index
    childcontroller = ChildController.new(parent_id: @parent.id)

    childcontroller.invoke(:index)

    assert_equal(200, childcontroller.status)

    assert_equal({ 'data' => @parent.children.map { |c| Views::Child.new(c).to_hash } },
                 childcontroller.hash_response)
  end

  def test_nested_create_append
    skip('unimplemented')

    data = { "name" => "c3" }
    childcontroller = ChildController.new(parent_id: @parent.id, data: data)

    childcontroller.invoke(:create)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(3, @parent.children.count, "@parent.children.count == 3")
    c3 = @parent.children.last
    assert_equal("c3", c3.name)

    assert_equal({ "data" => Views::Child.new(c3).to_hash },
                 childcontroller.hash_response)


  end

  def test_nested_create_bad_data
    skip('unimplemented')

    data = [{ "name" => "nc" }]
    childcontroller = ChildController.new(parent_id: @parent.id, data: data)

    childcontroller.invoke(:create)

    assert_equal(400, childcontroller.status)
  end

end
