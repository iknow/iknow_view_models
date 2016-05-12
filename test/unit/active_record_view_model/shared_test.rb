require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

class ActiveRecordViewModel::SharedTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  module WithCategory
    def setup
      build_viewmodel(:Category) do
        define_schema do |t|
          t.string :name
        end

        define_model do
          has_many :parents
        end

        define_viewmodel do
          attributes :name
          include TrivialAccessControl
        end
      end

      super
    end
  end

  module WithParent
    def setup
      build_viewmodel(:Parent) do
        define_schema do |t|
          t.string :name
          t.references :category, foreign_key: true # shared reference
        end

        define_model do
          belongs_to :category
        end

        define_viewmodel do
          attributes   :name
          association :category, shared: true
          include TrivialAccessControl
        end
      end

      super
    end
  end

  include WithParent
  include WithCategory

  def setup
    super
    @parent1 = Parent.create(name: "p1",
                             category: Category.new(name: "p1cat"))

    @parent2 = Parent.create(name: "p2")

    @category1 = Category.create(name: "Cat1")
  end

  def serialize_context
    Views::Parent.new_serialize_context(include: :category)
  end

  def test_create_from_view
    view = {
      "_type"    => "Parent",
      "name"     => "p",
      "category"   => { "_ref" => "r1" },
    }
    refs = {
      "r1" => { "_type" => "Category", "name" => "newcat"}
    }

    pv = Views::Parent.deserialize_from_view(view, references: refs)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal("p", p.name)

    assert(p.category.present?)
    assert_equal("newcat", p.category.name)
  end

  def test_serialize_view
    view, refs = serialize_with_references(Views::Parent.new(@parent1), serialize_context: serialize_context)
    cat1_ref = refs.detect { |_, v| v['_type'] == 'Category' }.first

    assert_equal({cat1_ref => { '_type' => "Category",
                                'id'    => @parent1.category.id,
                                'name'  => @parent1.category.name }},
                 refs)

    assert_equal({ "_type" => "Parent",
                   "id" => @parent1.id,
                   "name" => @parent1.name,
                   "category" => {"_ref" => cat1_ref}},
                 view)
  end

  def test_shared_eager_include
    parent_includes = Views::Parent.eager_includes

    expected = { }

    assert_equal(expected, parent_includes)

    extra_includes = Views::Parent.eager_includes(serialize_context: Views::Parent.new_serialize_context(include: :category))

    assert_equal({ 'category' => {} }, extra_includes)
  end

  def test_shared_add_reference
    alter_by_view!(Views::Parent, @parent2, serialize_context: serialize_context) do |p2view, refs|
      p2view['category'] = { '_ref' => 'myref' }
      refs['myref'] = update_hash_for(Views::Category, @category1)
    end

    assert_equal(@category1, @parent2.category)
  end

  def test_shared_add_multiple_references
    alter_by_view!(Views::Parent, [@parent1, @parent2], serialize_context: serialize_context) do |(p1view, p2view), refs|
      refs.delete(p1view['category']['_ref'])
      refs['myref'] = update_hash_for(Views::Category, @category1)

      p1view['category'] = { '_ref' => 'myref' }
      p2view['category'] = { '_ref' => 'myref' }
    end

    assert_equal(@category1, @parent1.category)
    assert_equal(@category1, @parent2.category)
  end

  def test_shared_requires_all_references
    ex = assert_raises(ViewModel::DeserializationError) do
      alter_by_view!(Views::Parent, @parent2, serialize_context: serialize_context) do |p2view, refs|
        refs['spurious_ref'] = { '_type' => 'Parent', 'id' => @parent1.id }
      end
    end
    assert_match(/was not referred to/, ex.message)
  end

  def test_shared_requires_valid_references
    ex = assert_raises(ViewModel::DeserializationError) do
      serialize_context = Views::Parent.new_serialize_context(include: :category)
      alter_by_view!(Views::Parent, @parent1, serialize_context: serialize_context) do |p1view, refs|
        refs.clear # remove the expected serialized refs
      end
    end
    assert_match(/Could not parse unresolvable reference/, ex.message)
  end

  def test_shared_requires_assignable_type
    ex = assert_raises(ViewModel::DeserializationError) do
      serialize_context = Views::Parent.new_serialize_context(include: :category)
      alter_by_view!(Views::Parent, @parent1, serialize_context: serialize_context) do |p1view, refs|
        p1view['category'] = { '_ref' => 'p2' }
        refs['p2'] = update_hash_for(Views::Parent, @parent2)
      end
    end
    assert_match(/can't refer to/, ex.message)
  end

  def test_shared_requires_unique_references
    serialize_context = Views::Parent.new_serialize_context(include: :category)
    c1_ref = update_hash_for(Views::Category, @category1)
    ex = assert_raises(ViewModel::DeserializationError, serialize_context: serialize_context) do
      alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1view, p2view), refs|
        refs['c_a'] = c1_ref.dup
        refs['c_b'] = c1_ref.dup
        p1view['category'] = { '_ref' => 'c_a' }
        p2view['category'] = { '_ref' => 'c_b' }
      end
    end
    assert_match(/Duplicate/, ex.message)
  end

  def test_shared_updates_shared_data
    serialize_context = Views::Parent.new_serialize_context(include: :category)
    alter_by_view!(Views::Parent, @parent1, serialize_context: serialize_context) do |p1view, refs|
      category_ref = p1view['category']['_ref']
      refs[category_ref]['name'] = 'newcatname'
    end
    assert_equal('newcatname', @parent1.category.name)
  end

  def test_shared_delete_reference
    serialize_context = Views::Parent.new_serialize_context(include: :category)
    alter_by_view!(Views::Parent, @parent1, serialize_context: serialize_context) do |p1view, refs|
      category_ref = p1view['category']['_ref']
      refs.delete(category_ref)
      p1view['category'] = nil
    end
    assert_equal(nil, @parent1.category)
    assert(Category.where(id: @category1.id).present?)
  end
end