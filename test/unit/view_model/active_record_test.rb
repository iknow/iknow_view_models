# -*- coding: utf-8 -*-

require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"
require 'minitest/unit'

require "view_model/active_record"

class ViewModel::ActiveRecordTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:Trivial) do
      define_schema
      define_model {}
      define_viewmodel { root! }
    end

    build_viewmodel(:Parent) do
      define_schema do |t|
        t.string :name, null: false
        t.integer :one, null: false, default: 1
        t.integer :lock_version, null: false
      end

      define_model do
        validates :name, exclusion: {
                    in: %w[invalid],
                    message: 'invalid due to matching test sentinel',
                  }
      end

      define_viewmodel do
        root!
        attributes :name, :lock_version
        attribute :one, read_only: true
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

  def test_find_multiple
    pv1, pv2 = ParentView.find([@parent1.id, @parent2.id])
    assert_equal(@parent1, pv1.model)
    assert_equal(@parent2, pv2.model)
  end

  def test_find_errors
    ex = assert_raises(ViewModel::DeserializationError::NotFound) do
      ParentView.find([@parent1.id, 9999])
    end
    assert_equal([ViewModel::Reference.new(ParentView, 9999)], ex.nodes)
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

  def test_create_from_empty_view
    view = TrivialView.deserialize_from_view({ '_type' => 'Trivial' })
    model = view.model
    assert(!model.new_record?)
  end

  def test_create_from_view_with_explicit_id
    view = {
      "_type" => "Parent",
      "id"    => 9999,
      "name"  => "p",
      "_new"  => true
    }
    pv = ParentView.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)
    assert_equal(9999, p.id)
  end

  def test_create_explicit_id_raises_with_id
    view = {
      "_type" => "Parent",
      "id"    => 9999,
      "_new"  => true
    }
    ex = assert_raises(ViewModel::DeserializationError::DatabaseConstraint) do
      ParentView.deserialize_from_view(view)
    end
    assert_match(/not-null constraint/, ex.message)
    assert_equal([ViewModel::Reference.new(ParentView, 9999)], ex.nodes)
  end

  def test_read_only_raises_with_id
    view = {
      "_type" => "Parent",
      "one"   => 2,
      "id"    => 9999,
      "_new"  => true
    }
    ex = assert_raises(ViewModel::DeserializationError::ReadOnlyAttribute) do
      ParentView.deserialize_from_view(view)
    end
    assert_match("one", ex.attribute)
    assert_equal([ViewModel::Reference.new(ParentView, 9999)], ex.nodes)
  end

  def test_visibility_raises
    parentview = ParentView.new(@parent1)

    assert_raises(ViewModel::AccessControlError) do
      no_view_context = ViewModelBase.new_serialize_context(can_view: false)
      parentview.to_hash(serialize_context: no_view_context)
    end

    assert_raises(ViewModel::AccessControlError) do
      no_view_context = ViewModelBase.new_deserialize_context(can_view: false)
      ParentView.deserialize_from_view({'_type' => 'Parent', 'name' => 'p'},
                                       deserialize_context: no_view_context)
    end
  end

  def test_editability_checks_create
    context = ViewModelBase.new_deserialize_context
    pv = ParentView.deserialize_from_view({ '_type' => 'Parent', 'name' => 'p' },
                                          deserialize_context: context)

    assert_equal([pv.to_reference],
                 context.valid_edit_refs)
  end

  def test_editability_checks_create_on_empty_record
    context = ViewModelBase.new_deserialize_context
    view = TrivialView.deserialize_from_view({'_type' => 'Trivial' },
                                             deserialize_context: context)

    ref = view.to_reference
    assert_equal([ref], context.valid_edit_refs)

    changes = context.valid_edit_changes(ref)
    assert_equal(true, changes.new?)
    assert_empty(changes.changed_attributes)
    assert_empty(changes.changed_associations)
    assert_equal(false, changes.deleted?)
  end

  def test_editability_raises
    no_edit_context = ViewModelBase.new_deserialize_context(can_edit: false)

    ex = assert_raises(ViewModel::AccessControlError) do
      # create
      ParentView.deserialize_from_view({ "_type" => "Parent", "name" => "p" }, deserialize_context: no_edit_context)
    end
    assert_match(/Illegal edit/, ex.message)

    ex = assert_raises(ViewModel::AccessControlError) do
      # edit
      v = ParentView.new(@parent1).to_hash.merge("name" => "p2")
      ParentView.deserialize_from_view(v, deserialize_context: no_edit_context)
    end
    assert_match(/Illegal edit/, ex.message)

    ex = assert_raises(ViewModel::AccessControlError) do
      # destroy
      ParentView.new(@parent1).destroy!(deserialize_context: no_edit_context)
    end
    assert_match(/Illegal edit/, ex.message)
  end

  def test_valid_edit_raises
    no_edit_context = ViewModelBase.new_deserialize_context(can_change: false)

    ex = assert_raises(ViewModel::AccessControlError) do
      # create
      ParentView.deserialize_from_view({ "_type" => "Parent", "name" => "p" }, deserialize_context: no_edit_context)
    end
    assert_match(/Illegal edit/, ex.message)

    ex = assert_raises(ViewModel::AccessControlError) do
      # edit
      v = ParentView.new(@parent1).to_hash.merge("name" => "p2")
      ParentView.deserialize_from_view(v, deserialize_context: no_edit_context)
    end
    assert_match(/Illegal edit/, ex.message)

    ex = assert_raises(ViewModel::AccessControlError) do
      # destroy
      ParentView.new(@parent1).destroy!(deserialize_context: no_edit_context)
    end
    assert_match(/Illegal edit/, ex.message)
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
    assert_raises(ViewModel::DeserializationError::DuplicateNodes) do
      ParentView.deserialize_from_view(view)
    end
  end

  def test_create_invalid_type
     build_viewmodel(:Invalid) do
      define_schema { |t| }
      define_model {}
      define_viewmodel {}
    end

    ex = assert_raises(ViewModel::DeserializationError::InvalidSyntax) do
      ParentView.deserialize_from_view({ "target" => [] })
    end
    assert_match(/"_type" wasn't supplied/, ex.message)

    ex = assert_raises(ViewModel::DeserializationError::InvalidViewType) do
      ParentView.deserialize_from_view({ "_type" => "Invalid" })
    end

    ex = assert_raises(ViewModel::DeserializationError::UnknownView) do
      ParentView.deserialize_from_view({ "_type" => "NotAViewmodelType" })
    end
  end

  def test_edit_attribute_from_view
    alter_by_view!(ParentView, @parent1) do |view, refs|
      view['name'] = 'renamed'
    end
    assert_equal('renamed', @parent1.name)
  end

  def test_edit_attribute_validation_failure
    old_name = @parent1.name
    ex = assert_raises(ViewModel::DeserializationError::Validation) do
      alter_by_view!(ParentView, @parent1) do |view, refs|
        view['name'] = 'invalid'
      end
    end
    assert_equal(old_name, @parent1.name, 'validation failure causes rollback')
    assert_equal(ex.attribute, "name")
    assert_equal(ex.reason, "invalid due to matching test sentinel")
  end

  def test_edit_readonly_attribute
    assert_raises(ViewModel::DeserializationError::ReadOnlyAttribute) do
      ex = alter_by_view!(ParentView, @parent1) do |view, refs|
        view['one'] = 2
      end
      assert_equal("one", ex.attribute)
    end
  end

  def test_edit_missing_root
    view = {
      "_type" => "Parent",
      "id"    => 9999
    }

    ex = assert_raises(ViewModel::DeserializationError::NotFound) do
      ParentView.deserialize_from_view(view)
    end

    assert_equal(ex.nodes, [ViewModel::Reference.new(ParentView, 9999)])
  end

  def test_optimistic_locking
    @parent1.name = "changed"
    @parent1.save!

    assert_raises(ViewModel::DeserializationError::LockFailure) do
      alter_by_view!(ParentView, @parent1) do |view, _refs|
        view['lock_version'] = 0
      end
    end
  end


  # Tests for overriding the serialization of attributes using custom viewmodels
  class CustomAttributeViewsTests < ActiveSupport::TestCase
    include ARVMTestUtilities

    class ComplexAttributeView < ViewModel
      attribute :array

      def serialize_view(json, serialize_context:)
        json.a array[0]
        json.b array[1]
      end

      def self.deserialize_from_view(hash_data, references: {}, deserialize_context:)
        array = [hash_data["a"], hash_data["b"]]
        self.new(array)
      end
    end

    def before_all
      super
      build_viewmodel(:Pair) do
        define_schema do |t|
          t.column :pair, "integer[]"
        end

        define_model do
        end

        define_viewmodel do
          attribute :pair, using: ComplexAttributeView
        end
      end
    end

    def setup
      super
      @pair = Pair.create!(pair: [1,2])
    end

    def test_serialize_view
      view, _refs = serialize_with_references(PairView.new(@pair))

      assert_equal({ "_type"    => "Pair",
                     "_version" => 1,
                     "id"       => @pair.id,
                     "pair"     => { "a" => 1, "b" => 2 } },
                   view)
    end

    def test_create
      view = { "_type" => "Pair", "pair" => { "a" => 3, "b" => 4 } }
      pv = PairView.deserialize_from_view(view)
      assert_equal([3,4], pv.model.pair)
    end
  end

  # Parent view should be correctly passed down the tree when deserializing
  class DeserializationParentContextTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    class RefError < RuntimeError
      attr_reader :ref
      def initialize(ref)
        super("Boom")
        @ref = ref
      end
    end

    def before_all
      super

      build_viewmodel(:List) do
        define_schema do |t|
          t.integer :child_id
        end

        define_model do
          belongs_to :child, class_name: :List
        end

        define_viewmodel do
          association :child
          attribute :explode
          # Escape deserialization with the parent context
          define_method(:deserialize_explode) do |val, references:, deserialize_context: |
            raise RefError.new(deserialize_context.parent_ref) if val
          end
        end
      end
    end

    def setup
      @list = List.new(child: List.new(child: nil))
    end

    def test_deserialize_context
      view = {
        "_type" => "List",
        "id"    => 1000,
        "_new"  => true,
        "child" => {
          "_type" => "List",
        }}

      ref_error = assert_raises(RefError) do
        ListView.deserialize_from_view(view.deep_merge("child" => { "explode" => true }))
      end

      assert_equal(ListView, ref_error.ref.viewmodel_class)
      assert_equal(1000, ref_error.ref.model_id)

      ref_error = assert_raises(RefError) do
        ListView.deserialize_from_view(view.deep_merge("explode" => true))
      end

      assert_nil(ref_error.ref)
    end
  end

  # Parent view should be correctly passed down the tree when deserializing
  class DeferredConstraintTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      super

      build_viewmodel(:List) do
        define_schema do |t|
          t.integer :child_id
        end

        define_model do
          belongs_to :child, class_name: :List
        end

        define_viewmodel do
          root!
          association :child
        end
      end
      List.connection.execute("ALTER TABLE lists ADD CONSTRAINT unique_child UNIQUE (child_id) DEFERRABLE INITIALLY DEFERRED")
    end

    def test_deferred_constraint_violation
      l1 = List.create!(child: List.new)
      l2 = List.create!

      ex = assert_raises(ViewModel::DeserializationError::UniqueViolation) do
        alter_by_view!(ListView, l2) do |view, refs|
          view['child'] = { "_ref" => "r1" }
          refs["r1"] = { "_type" => "List", "id" => l1.child.id }
        end
      end

      constraint = 'unique_child'
      columns    = ['child_id']
      values     = l1.child.id.to_s

      assert_match(/#{constraint}/, ex.message)
      assert_equal(constraint, ex.constraint)
      assert_equal(columns, ex.columns)
      assert_equal(values, ex.values)

      assert_equal({ constraint: constraint, columns: columns, values: values, nodes: [] }, ex.meta)
    end
  end
end
