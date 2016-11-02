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

    build_viewmodel(:Parent) do
      define_schema do |t|
        t.string :name, null: false
        t.integer :one, null: false, default: 1
        t.integer :lock_version, null: false
      end

      define_model do
        validates :name, exclusion: {in: %w(invalid),
                                     message: 'invalid due to matching test sentinel' }
      end

      define_viewmodel do
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
    ex = assert_raises(ViewModel::DeserializationError) do
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
    ex = assert_raises(ViewModel::DeserializationError) do
      ParentView.deserialize_from_view(view)
    end
    assert_match(/read only/, ex.message)
    assert_equal([ViewModel::Reference.new(ParentView, 9999)], ex.nodes)
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
    assert_equal([ViewModel::Reference.new(ParentView, nil)], context.edit_checks)
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
    assert_raises(ViewModel::DeserializationError) do
      alter_by_view!(ParentView, @parent1) do |view, refs|
        view['name'] = 'invalid'
      end
    end
    assert_equal(old_name, @parent1.name, 'validation failure causes rollback')
  end

  def test_edit_readonly_attribute
    assert_raises(ViewModel::DeserializationError) do
      alter_by_view!(ParentView, @parent1) do |view, refs|
        view['one'] = 2
      end
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
      alter_by_view!(ParentView, @parent1) do |view, refs|
        view['lock_version'] = 0
      end
     end
  end

  # Tests for `editable?` behaviour
  class EditCheckTests < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      super
      build_viewmodel(:List) do
        define_schema do |t|
          t.integer :car
          t.integer :cdr_id
        end

        define_model do
          belongs_to :cdr, class_name: :List, dependent: :destroy
        end

        define_viewmodel do
          attr_reader :edit_data
          attribute   :car
          association :cdr

          def editable?(deserialize_context:, changed_associations:, deleted:)
            EditCheckTests.add_edit_check(self.to_reference,
                                          [model.changes.keys, changed_associations, deleted])
            super
          end
        end
      end

      build_viewmodel(:Invisible) do
        define_schema {}
        define_model {}
        define_viewmodel do
          def visible?(*)
            self.access_check_error = ViewModel::SerializationError.new("view-failed")
            false
          end
        end
      end

      build_viewmodel(:Immutable) do
        define_schema do |t|
          t.integer :i
        end
        define_model {}
        define_viewmodel do
          attribute :i

          def editable?(*)
            self.access_check_error = ViewModel::DeserializationError.new("edit-failed")
            false
          end
        end
      end
    end

     class << self
       def reset_edit_checks
         @edit_checks = {}
       end

       def add_edit_check(ref, data)
         @edit_checks[ref] = data
       end

       def edit_check(ref)
         @edit_checks[ref]
       end
     end

     delegate :reset_edit_checks, :add_edit_check, :edit_check, to: :class

     def setup
       reset_edit_checks
     end

     def test_custom_view_failure
       v = Invisible.create!
       ex = assert_raises(ViewModel::SerializationError) do
         InvisibleView.new(v).to_hash
       end
       assert_match(/view-failed/, ex.message)
     end

     def test_custom_edit_failure
       v = Immutable.create!
       ex = assert_raises(ViewModel::DeserializationError) do
         alter_by_view!(ImmutableView, v) do |view, refs|
           view["i"] = 1
         end
       end
       assert_match(/edit-failed/, ex.message)
     end

     def test_editable_change_attribute
       l = List.create!(car: 1)

       alter_by_view!(ListView, l) do |view, refs|
         view["car"] = nil
       end

       edits = edit_check(ViewModel::Reference.new(ListView, l.id))
       assert_equal([["car"], [], false], edits)
     end

     def test_editable_add_association
       l = List.create!(car: 1)

       alter_by_view!(ListView, l) do |view, refs|
         view["cdr"] = { "_type" => "List", "car" => 2 }
       end

       l_edits = edit_check(ViewModel::Reference.new(ListView, l.id))
       assert_equal([["cdr_id"], ["cdr"], false], l_edits)

       c_edits = edit_check(ViewModel::Reference.new(ListView, nil))
       assert_equal([["car"], [], false], c_edits)
     end

     def test_editable_change_association
       l = List.create!(car: 1, cdr: List.new(car: 2))
       l2 = l.cdr

       alter_by_view!(ListView, l) do |view, refs|
         view["cdr"] = { "_type" => "List", "car" => 2 }
       end

       l_edits = edit_check(ViewModel::Reference.new(ListView, l.id))
       assert_equal([["cdr_id"], ["cdr"], false], l_edits)

       l2_edits = edit_check(ViewModel::Reference.new(ListView, l2.id))
       assert_equal([[], [], true], l2_edits)

       c_edits = edit_check(ViewModel::Reference.new(ListView, nil))
       assert_equal([["car"], [], false], c_edits)
     end

     def test_editable_delete_association
       l = List.create!(car: 1, cdr: List.new(car: 2))
       l2 = l.cdr

       alter_by_view!(ListView, l) do |view, refs|
         view["cdr"] = nil
       end

       l_edits = edit_check(ViewModel::Reference.new(ListView, l.id))
       assert_equal([["cdr_id"], ["cdr"], false], l_edits)

       l2_edits = edit_check(ViewModel::Reference.new(ListView, l2.id))
       assert_equal([[], [], true], l2_edits)
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

      def self.deserialize_from_view(hash_data, deserialize_context:)
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

  # Tests for functionality common to all ARVM instances, but require some kind
  # of relationship.
  class RelationshipTests < ActiveSupport::TestCase
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
        end
      end

      build_viewmodel(:Child) do
        define_schema do |t|
          t.references :parent, null: false, foreign_key: true
          t.string :name
        end

        define_model do
          belongs_to :parent, inverse_of: :children
        end

        define_viewmodel do
          attributes :name
        end
      end
    end

    def test_updated_associations_returned
      # This test ensures the data is passed back through the context. The tests
      # for the values are in the relationship-specific tests.

      updated_by_view = ->(view) do
        context = ViewModelBase.new_deserialize_context
        ParentView.deserialize_from_view(view, deserialize_context: context)
        context.updated_associations
      end

      assert_equal({},
                   updated_by_view.({ '_type' => 'Parent',
                                      'name' => 'p' }))

      assert_equal({ 'children' => {} },
                   updated_by_view.({ '_type' => 'Parent',
                                      'name' => 'p',
                                      'children' => [] }))
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
          define_method(:deserialize_explode) do |val, deserialize_context: |
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
end
