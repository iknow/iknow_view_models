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
    puts "setup done"
  end

  def test_show
    parentcontroller = ParentController.new(id: @parent.id)
    parentcontroller.invoke(:show)

    assert_equal(200, parentcontroller.status)
    assert_equal(parentcontroller.hash_response,
                 { "data" => ParentView.new(@parent).to_hash })
  end

  def test_index
    p2 = Parent.create(name: "p2")

    parentcontroller = ParentController.new
    parentcontroller.invoke(:index)

    assert_equal(200, parentcontroller.status)

    assert_equal(parentcontroller.hash_response,
                 { "data" => [ParentView.new(@parent).to_hash, ParentView.new(p2).to_hash] })
  end

  def test_create
    data = {
        "name" => "p2",
        "label" => { "text" => "l" },
        "target" => { "text" => "t" },
        "children" => [{ "name" => "c1" }, { "name" => "c2" }]
    }

    parentcontroller = ParentController.new(data: data)
    parentcontroller.invoke(:create)

    assert_equal(200, parentcontroller.status,
                 parentcontroller.hash_response.inspect)

    p = Parent.where(name: "p2").first
    assert(p.present?, "p created")

    assert_equal({ "data" => ParentView.new(p).to_hash },
                 parentcontroller.hash_response)
  end

  def test_update
    data = { "id" => @parent.id, "name" => "new" }
    parentcontroller = ParentController.new(id: @parent.id, data: data)
    parentcontroller.invoke(:update)

    assert_equal(200, parentcontroller.status)
    @parent.reload
    assert_equal("new", @parent.name)
    assert_equal(parentcontroller.hash_response,
                 { "data" => ParentView.new(@parent).to_hash })
  end

  def test_destroy
    parentcontroller = ParentController.new(id: @parent.id)
    parentcontroller.invoke(:destroy)
    assert(Parent.where(id: @parent.id).blank?)
    assert_equal(200, parentcontroller.status)
    assert_equal({ "data" => nil }, parentcontroller.hash_response)
  end

  def test_show_missing
    parentcontroller = ParentController.new(id: 9999)
    parentcontroller.invoke(:show)

    assert_equal(404, parentcontroller.status)
    assert_equal(parentcontroller.hash_response,
                 { "errors" => [{ "status" => 404, "detail" => "Couldn't find Parent with 'id'=9999" }] })
  end

  def test_update_incorrect
    data = { "id" => @parent.id, "name" => "new" }
    parentcontroller = ParentController.new(id: 9999, data: data)
    parentcontroller.invoke(:update)

    assert_equal(400, parentcontroller.status)
    assert_equal(parentcontroller.hash_response,
                 { "errors" => [{ "status" => 400, "detail" => "Invalid update action: provided data represents a different object" }] })
  end

  def test_create_existing
    data = { "id" => @parent.id, "name" => "p2" }

    parentcontroller = ParentController.new(data: data)
    parentcontroller.invoke(:create)

    assert_equal(400, parentcontroller.status)
    assert_equal(parentcontroller.hash_response,
                 { "errors" => [{ "status" => 400, "detail" => "Not a create action: provided data represents an existing object" }] })
  end

  def test_create_invalid_shallow_validation
    data = { "children" => [{ "age" => 42 }] }
    parentcontroller = ParentController.new(data: data)
    parentcontroller.invoke(:create)

    assert_equal(parentcontroller.hash_response,
                 { "errors" => [{ "status" => 500,
                                  "detail" => "Validation failed: Age must be less than 42" }] } )
  end

  def test_create_invalid_shallow_constraint
    data = { "children" => [{ "age" => 1 }] }
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

    assert_equal({ "errors" => [{ "status" => 404,
                                  "detail" => "Couldn't find Parent with 'id'=9999" }] },
                 parentcontroller.hash_response)
    assert_equal(404, parentcontroller.status)
  end

  #### Controller for nested model

  def test_nested_index
    childcontroller = ChildController.new(parent_id: @parent.id)

    childcontroller.invoke(:index)

    assert_equal(200, childcontroller.status)

    assert_equal(childcontroller.hash_response,
                 { "data" => @parent.children.map { |c| ChildView.new(c).to_hash } })
  end

  def test_nested_create_append
    data = { "name" => "c3" }
    childcontroller = ChildController.new(parent_id: @parent.id, data: data)

    childcontroller.invoke(:create)

    assert_equal(200, childcontroller.status, childcontroller.hash_response)

    @parent.reload

    assert_equal(3, @parent.children.count, "@parent.children.count == 3")
    c3 = @parent.children.last
    assert_equal("c3", c3.name)

    assert_equal({ "data" => ChildView.new(c3).to_hash },
                 childcontroller.hash_response)


  end

  def test_nested_create_bad_data
    data = [{ "name" => "nc" }]
    childcontroller = ChildController.new(parent_id: @parent.id, data: data)

    childcontroller.invoke(:create)

    assert_equal(400, childcontroller.status)
  end

end
