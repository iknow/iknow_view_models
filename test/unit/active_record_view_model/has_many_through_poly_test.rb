require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

class ActiveRecordViewModel::HasManyThroughPolyTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:TagA) do
      define_schema do |t|
        t.string :name
        t.string :tag_b_desc
      end

      define_model do
        has_many :parents_tag, dependent: :destroy, inverse_of: :tag
      end

      define_viewmodel do
        attributes :name

        include TrivialAccessControl
      end
    end

    build_viewmodel(:TagB) do
      define_schema do |t|
        t.string :name
        t.string :tag_b_desc
      end

      define_model do
        has_many :parents_tag, dependent: :destroy, inverse_of: :tag
      end

      define_viewmodel do
        attributes :name

        include TrivialAccessControl
      end
    end


    build_viewmodel(:Parent) do
      define_schema do |t|
        t.string :name
      end

      define_model do
        has_many :parents_tags, dependent: :destroy, inverse_of: :parent
      end

      define_viewmodel do
        attributes :name
        association :tags, shared: true, through: :parents_tags, through_order_attr: :position, viewmodels:[Views::TagA, Views::TagB]
        include TrivialAccessControl
      end
    end


    build_viewmodel(:ParentsTag) do
      define_schema do |t|
        t.references :parent, foreign_key: true
        t.references :tag
        t.string     :tag_type
        t.float      :position
      end

      define_model do
        belongs_to :parent
        belongs_to :tag, polymorphic: true
      end

      no_viewmodel
    end
  end

  private def context_with(*args)
    Views::Parent.new_serialize_context(include: args)
  end

  def setup
    @tag_a1, @tag_a2 = (1..2).map { |x| TagA.create(name: "tag A#{x}") }
    @tag_b1, @tag_b2 = (1..2).map { |x| TagB.create(name: "tag B#{x}") }

    @parent1 = Parent.create(name: 'p1',
                             parents_tags: [ParentsTag.new(tag: @tag_a1, position: 1.0),
                                            ParentsTag.new(tag: @tag_a2, position: 2.0),
                                            ParentsTag.new(tag: @tag_b1, position: 3.0),
                                            ParentsTag.new(tag: @tag_b2, position: 4.0)])

    @parent2 = Parent.create(name: 'p2',
                             parents_tags: [ParentsTag.new(tag: @tag_a1, position: 1.0),
                                            ParentsTag.new(tag: @tag_b1, position: 2.0),
                                            ParentsTag.new(tag: @tag_a1, position: 3.0)])

    super
  end

  def test_roundtrip
    # Objects are serialized to a view and deserialized, and should not be different when complete.

    alter_by_view!(Views::Parent, @parent1, serialize_context: context_with(:tags)) {}
    assert_equal('p1', @parent1.name)
    assert_equal([@tag_a1, @tag_a2, @tag_b1, @tag_b2],
                 @parent1.parents_tags.order(:position).map(&:tag))

    alter_by_view!(Views::Parent, @parent2, serialize_context: context_with(:tags)) {}
    assert_equal('p2', @parent2.name)
    assert_equal([@tag_a1, @tag_b1, @tag_a1],
                 @parent2.parents_tags.order(:position).map(&:tag))
  end

  def test_eager_includes
    includes = Views::Parent.eager_includes(serialize_context: context_with(:tags))
    assert_equal({ 'parents_tags' => { 'tag' => {} } }, includes)
  end

  def test_association_dependencies
    # TODO not part of ARVM; but depends on the particular context from #before_all
    # If we refactor out the contexts from their tests, this should go in another test file.

    root_updates, ref_updates = ActiveRecordViewModel::UpdateData.parse_hashes([{ '_type' => 'Parent' }])
    assert_equal({},
                 root_updates.first.association_dependencies(ref_updates),
                 'nothing loaded by default')

    root_updates, ref_updates = ActiveRecordViewModel::UpdateData.parse_hashes([{ '_type' => 'Parent',
                                                                                  'tags' => [{ '_ref' => 'r1' }] }],
                                                                               { 'r1' => { '_type' => 'TagB' } })

    assert_equal({ 'parents_tags' => {} },
                 root_updates.first.association_dependencies(ref_updates),
                 'mentioning tags causes through association loading')
  end


  def test_serialize
    view, refs = serialize_with_references(Views::Parent.new(@parent1),
                                           serialize_context: context_with(:tags))

    tag_data = view['tags'].map { |hash| refs[hash['_ref']] }
    assert_equal([{ 'id' => @tag_a1.id, '_type' => 'TagA', 'name' => 'tag A1' },
                  { 'id' => @tag_a2.id, '_type' => 'TagA', 'name' => 'tag A2' },
                  { 'id' => @tag_b1.id, '_type' => 'TagB', 'name' => 'tag B1' },
                  { 'id' => @tag_b2.id, '_type' => 'TagB', 'name' => 'tag B2' }],
                 tag_data)
  end

  def test_create_has_many_through
    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      refs.delete_if { |_, ref_hash| ref_hash['_type'] == 'Tag' }
      refs['t1'] = { '_type' => 'TagA', 'name' => 'new tagA' }
      refs['t2'] = { '_type' => 'TagB', 'name' => 'new tagB' }
      view['tags'] = [{ '_ref' => 't1' }, { '_ref' => 't2' }]
    end

    new_tag_a = TagA.find_by_name('new tagA')
    new_tag_b = TagB.find_by_name('new tagB')

    refute_nil(new_tag_a, 'new tag A created')
    refute_nil(new_tag_b, 'new tag B created')

    assert_equal([new_tag_a, new_tag_b],
                 @parent1.parents_tags.order(:position).map(&:tag))
  end

  def test_reordering_swap_type
    alter_by_view!(Views::Parent, @parent1, serialize_context: context_with(:tags)) do |view, refs|
      t1, t2, t3, t4 = view['tags']
      view['tags'] = [t3, t2, t1, t4]
    end
    assert_equal([@tag_b1, @tag_a2, @tag_a1, @tag_b2],
                 @parent1.parents_tags.order(:position).map(&:tag))
  end

  def test_delete
    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      refs.clear
      view['tags'] = []
    end
    assert_equal([], @parent1.parents_tags)
  end

end
