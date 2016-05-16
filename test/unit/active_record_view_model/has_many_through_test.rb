require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

class ActiveRecordViewModel::HasManyThroughTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:Parent) do
      define_schema do |t|
        t.string :name
      end

      define_model do
        has_many :parents_tags, dependent: :destroy, inverse_of: :parent
      end

      define_viewmodel do
        attributes :name
        association :tags, shared: true, through: :parents_tags
        include TrivialAccessControl
      end
    end

    build_viewmodel(:Tag) do
      define_schema do |t|
        t.string :name

      end

      define_model do
        has_many :parents_tag, dependent: :destroy, inverse_of: :tag
      end

      define_viewmodel do
        attributes :name

        include TrivialAccessControl
      end
    end


    build_viewmodel(:ParentsTag) do
      define_schema do |t|
        t.references :parent, foreign_key: true
        t.references :tag,    foreign_key: true
        t.float      :position
      end

      define_model do
        belongs_to :parent
        belongs_to :tag
        # TODO list membership?
      end

      no_viewmodel
    end
  end

  def setup
    @tag1, @tag2, @tag3 = (1..3).map { |x| Tag.create(name: "tag#{x}") }

    @parent1 = Parent.create(name: "p1",
                             parents_tags: [ParentsTag.new(tag: @tag1, position: 1.0),
                                            ParentsTag.new(tag: @tag2, position: 2.0)])
    @parent2 = Parent.create(name: "p1",
                             parents_tags: [ParentsTag.new(tag: @tag2, position: 1.0),
                                            ParentsTag.new(tag: @tag3, position: 2.0)])

    super
  end

  def test_serailize
    serialize_context = Views::Parent.new_serialize_context(include: :tags)
    view, refs = serialize_with_references(Views::Parent.new(@parent1), serialize_context: serialize_context)

    tag_data = view['tags'].map { |hash| refs[hash['_ref']] }
    assert_equal([{ 'id' => @tag1.id, '_type' => 'Tag', 'name' => 'tag1' },
                  { 'id' => @tag2.id, '_type' => 'Tag', 'name' => 'tag2' }],
                 tag_data)
  end

  def test_create_has_many_through
    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      refs.delete_if { |_, ref_hash| ref_hash['_type'] == 'Tag' }
      refs['t1'] = { '_type' => 'Tag', 'name' => 'new tag1' }
      refs['t2'] = { '_type' => 'Tag', 'name' => 'new tag2' }
      view['tags'] = [{ '_ref' => 't1' }, { '_ref' => 't2' }]
    end

    new_tag1, new_tag2 = Tag.where(name: ['new tag1', 'new tag2'])

    refute_nil(new_tag1, 'new tag 1 created')
    refute_nil(new_tag2, 'new tag 2 created')

    assert_equal([new_tag1, new_tag2], @parent1.parents_tags.order(:position).map(&:tag),
                 'database state updated')
  end

  def test_reordering
    skip("wip")

    serialize_context = Views::Parent.new_serialize_context(include: :tags)
    alter_by_view!(Views::Parent, @parent1, serialize_context: serialize_context) do |view, refs|
      view['tags'].reverse!
    end
    assert_equal([@tag2, @tag1],
                 @parent1.parents_tags.order(:position).map(&:tag))
  end
end
