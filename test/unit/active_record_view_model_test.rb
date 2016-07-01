# -*- coding: utf-8 -*-

require_relative "../helpers/arvm_test_utilities.rb"
require_relative "../helpers/arvm_test_models.rb"

require "minitest/autorun"
require 'minitest/unit'

require "active_record_view_model"

class ActiveRecordViewModelTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:Parent) do
      define_schema do |t|
        t.string :name
      end

      define_model do
        validates :name, exclusion: {in: %w(invalid),
                                     message: 'invalid due to matching test sentinel' }
      end

      define_viewmodel do
        attributes   :name
        include TrivialAccessControl
      end
    end
  end

  def setup
    @parent1 = Parent.create(name: "p1")
    @parent2 = Parent.create(name: "p2")

    super
  end

  ## Tests

  def test_find
    parentview = ParentView.find(@parent1.id)
    assert_equal(@parent1, parentview.model)
  end

  def test_load
    parentviews = ParentView.load
    assert_equal(2, parentviews.size)

    h = parentviews.index_by(&:id)
    assert_equal(@parent1, h[@parent1.id].model)
    assert_equal(@parent2, h[@parent2.id].model)
  end

  def test_create_from_view
    view = {
      "_type"    => "Parent",
      "name"     => "p",
    }

    pv = ParentView.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal("p", p.name)
  end

  def test_visibility_raises
    parentview = ParentView.new(@parent1)

    assert_raises(ViewModel::SerializationError) do
      no_view_context = ViewModelBase.new_serialize_context(can_view: false)
      parentview.to_hash(serialize_context: no_view_context)
    end
  end

  def test_editability_checks_create
    context = ViewModelBase.new_deserialize_context
    ParentView.deserialize_from_view({'_type' => 'Parent', 'name' => 'p'},
                                        deserialize_context: context)
    assert_equal([[ParentView, nil]], context.edit_checks)
  end

  def test_editability_raises
    no_edit_context = ViewModelBase.new_deserialize_context(can_edit: false)

    assert_raises(ViewModel::DeserializationError) do
      # create
      ParentView.deserialize_from_view({ "_type" => "Parent", "name" => "p" }, deserialize_context: no_edit_context)
    end

    assert_raises(ViewModel::DeserializationError) do
      # edit
      v = ParentView.new(@parent1).to_hash.merge("name" => "p2")
      ParentView.deserialize_from_view(v, deserialize_context: no_edit_context)
    end

    assert_raises(ViewModel::DeserializationError) do
      # destroy
      ParentView.new(@parent1).destroy!(deserialize_context: no_edit_context)
    end
  end

  def test_create_multiple
    view = [{'_type' => 'Parent', 'name' => 'newp1'},
            {'_type' => 'Parent', 'name' => 'newp2'}]

    result = ParentView.deserialize_from_view(view)

    new_parents = Parent.where(id: result.map{|x| x.model.id})

    assert_equal(%w{newp1 newp2}, new_parents.pluck(:name).sort)
  end

  def test_update_duplicate_specification
    view = [
      {'_type' => 'Parent', 'id' => @parent1.id},
      {'_type' => 'Parent', 'id' => @parent1.id},
    ]
    ex = assert_raises(ViewModel::DeserializationError) do
      ParentView.deserialize_from_view(view)
    end

    assert_match(/Duplicate root/, ex.message)
  end

  def test_create_invalid_type
     build_viewmodel(:Invalid) do
      define_schema { |t| }
      define_model {}
      define_viewmodel {}
    end

    ex = assert_raises(ViewModel::DeserializationError) do
      ParentView.deserialize_from_view({ "target" => [] })
    end
    assert_match(/"_type" wasn't supplied/, ex.message)

    ex = assert_raises(ViewModel::DeserializationError) do
      ParentView.deserialize_from_view({ "_type" => "Invalid" })
    end
    assert_match(/incorrect root viewmodel type/, ex.message)

    ex = assert_raises(ViewModel::DeserializationError) do
      ParentView.deserialize_from_view({ "_type" => "NotAViewmodelType" })
    end
    assert_match(/ViewModel\b.*\bnot found/, ex.message)
  end

  def test_edit_attribute_from_view
    alter_by_view!(ParentView, @parent1) do |view, refs|
      view['name'] = 'renamed'
    end
    assert_equal('renamed', @parent1.name)
  end

  def test_edit_attribute_validation_failure
    old_name = @parent1.name
    assert_raises(ActiveRecord::RecordInvalid) do
      alter_by_view!(ParentView, @parent1) do |view, refs|
        view['name'] = 'invalid'
      end
    end
    assert_equal(old_name, @parent1.name, 'validation failure causes rollback')
  end

end
