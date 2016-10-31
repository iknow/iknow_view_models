require_relative "../../../helpers/arvm_test_utilities.rb"
require_relative "../../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "view_model/active_record"

class ViewModel::ActiveRecord::HasManyThroughTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def self.build_parent(arvm_test_case)
    arvm_test_case.build_viewmodel(:Parent) do
      define_schema do |t|
        t.string :name
      end

      define_model do
        has_many :parents_tags, dependent: :destroy, inverse_of: :parent
      end

      define_viewmodel do
        attributes :name
        association :tags, shared: true, through: :parents_tags, through_order_attr: :position
      end
    end
  end

  def self.build_tag(arvm_test_case, with: [])
    use_childtag = with.include?(:ChildTag)
    arvm_test_case.build_viewmodel(:Tag) do
      define_schema do |t|
        t.string :name
      end

      define_model do
        has_many :parents_tags, dependent: :destroy, inverse_of: :tag
        if use_childtag
          has_many :child_tags, dependent: :destroy, inverse_of: :tag
        end
      end

      define_viewmodel do
        attributes :name
        if use_childtag
          associations :child_tags
        end
      end
    end
  end

  def self.build_childtag(arvm_test_case)
    arvm_test_case.build_viewmodel(:ChildTag) do
      define_schema do |t|
        t.string :name
        t.references :tag, foreign_key: true
      end

      define_model do
        belongs_to :tag, dependent: :destroy, inverse_of: :child_tag
      end

      define_viewmodel do
        attributes :name
      end
    end
  end

  def self.build_join_table_model(arvm_test_case)
    arvm_test_case.build_viewmodel(:ParentsTag) do
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

  def before_all
    super

    self.class.build_parent(self)
    self.class.build_tag(self)
    self.class.build_join_table_model(self)
  end

  private def context_with(*args)
    ParentView.new_serialize_context(include: args)
  end

  def setup
    super

    @tag1, @tag2, @tag3 = (1..3).map { |x| Tag.create(name: "tag#{x}") }

    @parent1 = Parent.create(name: 'p1',
                             parents_tags: [ParentsTag.new(tag: @tag1, position: 1.0),
                                            ParentsTag.new(tag: @tag2, position: 2.0)])

    @parent2 = Parent.create(name: 'p2',
                             parents_tags: [ParentsTag.new(tag: @tag3, position: 1.0),
                                            ParentsTag.new(tag: @tag3, position: 2.0),
                                            ParentsTag.new(tag: @tag3, position: 3.0)])

    enable_logging!
  end

  def test_loading_batching
    context = context_with(:tags)
    log_queries do
      parent_views = ParentView.load(serialize_context: context)
      serialize(parent_views, serialize_context: context)
    end

    assert_equal(['Parent Load', 'ParentsTag Load', 'Tag Load'],
                 logged_load_queries)
  end

  def test_roundtrip
    # Objects are serialized to a view and deserialized, and should not be different when complete.

    alter_by_view!(ParentView, @parent1, serialize_context: context_with(:tags)) {}
    assert_equal('p1', @parent1.name)
    assert_equal([@tag1, @tag2], @parent1.parents_tags.order(:position).map(&:tag))

    alter_by_view!(ParentView, @parent2, serialize_context: context_with(:tags)) {}
    assert_equal('p2', @parent2.name)
    assert_equal([@tag3, @tag3, @tag3], @parent2.parents_tags.order(:position).map(&:tag))
  end

  def test_eager_includes
    includes = ParentView.eager_includes(serialize_context: context_with(:tags))
    assert_equal(DeepPreloader::Spec.new('parents_tags' => DeepPreloader::Spec.new('tag' => DeepPreloader::Spec.new)), includes)
  end

  def test_preload_dependencies
    # TODO not part of ARVM; but depends on the particular context from #before_all
    # If we refactor out the contexts from their tests, this should go in another test file.

    root_updates, ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes([{ '_type' => 'Parent' }])
    assert_equal(DeepPreloader::Spec.new,
                 root_updates.first.preload_dependencies(ref_updates),
                 'nothing loaded by default')

    root_updates, ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes(
      [{ '_type' => 'Parent',
         'tags' => [{ '_ref' => 'r1' }] }],
      { 'r1' => { '_type' => 'Tag' } })

    assert_equal(DeepPreloader::Spec.new('parents_tags' => DeepPreloader::Spec.new('tag' => DeepPreloader::Spec.new)),
                 root_updates.first.preload_dependencies(ref_updates),
                 'mentioning tags and child_tags causes through association loading')
  end

  def test_updated_associations
    root_updates, ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes(
      [{ '_type' => 'Parent',
         'tags' => [{ '_ref' => 'r1' }] }],
      { 'r1' => { '_type' => 'Tag', } })

    assert_equal({ 'tags' => {} },
                 root_updates.first.updated_associations(ref_updates),
                 'mentioning tags causes through association loading')

  end

  def test_serialize
    view, refs = serialize_with_references(ParentView.new(@parent1),
                                           serialize_context: context_with(:tags))

    tag_data = view['tags'].map { |hash| refs[hash['_ref']] }
    assert_equal([{ 'id' => @tag1.id, '_type' => 'Tag', 'name' => 'tag1' },
                  { 'id' => @tag2.id, '_type' => 'Tag', 'name' => 'tag2' }],
                 tag_data)
  end

  def test_create_has_many_through
    alter_by_view!(ParentView, @parent1) do |view, refs|
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

  def test_delete
    alter_by_view!(ParentView, @parent1) do |view, refs|
      refs.clear
      view['tags'] = []
    end
    assert_equal([], @parent1.parents_tags)
  end

  def test_reordering
    alter_by_view!(ParentView, @parent1, serialize_context: context_with(:tags)) do |view, refs|
      view['tags'].reverse!
    end
    assert_equal([@tag2, @tag1],
                 @parent1.parents_tags.order(:position).map(&:tag))
  end

  def test_child_edit_doesnt_editcheck_parent
    # editing child doesn't edit check parent
    d_context = ParentView.new_deserialize_context
    alter_by_view!(ParentView, @parent1, serialize_context: context_with(:tags), deserialize_context: d_context) do |view, refs|
      refs[view['tags'][0]["_ref"]]["name"] = "changed"
    end
    assert(d_context.edit_checks.include?(ViewModel::Reference.new(TagView, @parent1.parents_tags.order(:position).first.tag_id)))
    refute(d_context.edit_checks.include?(ViewModel::Reference.new(ParentView, @parent1.id)))
  end

  def test_child_reordering_editchecks_parent
    d_context = ParentView.new_deserialize_context
    alter_by_view!(ParentView, @parent1, serialize_context: context_with(:tags), deserialize_context: d_context) do |view, refs|
      view['tags'].reverse!
    end
    assert(d_context.edit_checks.include?(ViewModel::Reference.new(ParentView, @parent1.id)))
  end

  def test_child_deletion_editchecks_parent
    d_context = ParentView.new_deserialize_context
    alter_by_view!(ParentView, @parent1, serialize_context: context_with(:tags), deserialize_context: d_context) do |view, refs|
      removed = view['tags'].pop['_ref']
      refs.delete(removed)
    end
    assert(d_context.edit_checks.include?(ViewModel::Reference.new(ParentView, @parent1.id)))
  end

  def test_child_addition_editchecks_parent
    d_context = ParentView.new_deserialize_context
    alter_by_view!(ParentView, @parent1, serialize_context: context_with(:tags), deserialize_context: d_context) do |view, refs|
      view['tags'] << { '_ref' => 't_new' }
      refs['t_new'] = { '_type' => 'Tag', 'name' => 'newest tag' }
    end
    assert(d_context.edit_checks.include?(ViewModel::Reference.new(ParentView, @parent1.id)))
    assert(d_context.edit_checks.include?(ViewModel::Reference.new(TagView, nil)))
  end

  def test_reordering_multi
    alter_by_view!(ParentView, @parent2, serialize_context: context_with(:tags)) do |view, refs|
      view['tags'].reverse!
    end
    assert_equal([@tag3, @tag3, @tag3],
                 @parent2.parents_tags.order(:position).map(&:tag))
  end

  class RenamingTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      super

      ViewModel::ActiveRecord::HasManyThroughTest.build_tag(self)

      build_viewmodel(:Parent) do
        define_schema do |t|
          t.string :name
        end

        define_model do
          has_many :parents_tags, dependent: :destroy, inverse_of: :parent
        end

        define_viewmodel do
          attributes :name
          association :tags, shared: true, through: :parents_tags, through_order_attr: :position, as: :something_else
        end
      end

      ViewModel::ActiveRecord::HasManyThroughTest.build_join_table_model(self)
    end


    def setup
      super

      @parent = Parent.create(parents_tags: [ParentsTag.new(tag: Tag.new(name: 'tag name'))])

      enable_logging!
    end

    def test_dependencies
      root_updates, ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes([{ '_type' => 'Parent', 'something_else' => [] }])
      assert_equal(DeepPreloader::Spec.new('parents_tags' => DeepPreloader::Spec.new('tag' => DeepPreloader::Spec.new)),
                   root_updates.first.preload_dependencies(ref_updates))
      assert_equal({ 'something_else' => {} }, root_updates.first.updated_associations(ref_updates))
    end

    def test_renamed_roundtrip
      context = ParentView.new_serialize_context(include: :something_else)
      alter_by_view!(ParentView, @parent, serialize_context: context) do |view, refs|
        assert_equal({refs.keys.first => {'id'    => @parent.parents_tags.first.tag.id,
                                          '_type' => 'Tag',
                                          'name'  => 'tag name'}}, refs)
        assert_equal([{ '_ref' => refs.keys.first }],
                     view['something_else'])

        refs.clear
        refs['new'] = {'_type' => 'Tag', 'name' => 'tag new name'}
        view['something_else'] = [{'_ref' => 'new'}]
      end

      assert_equal('tag new name', @parent.parents_tags.first.tag.name)
    end
  end

  class WithChildTagTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      super

      container = ViewModel::ActiveRecord::HasManyThroughTest
      container.build_parent(self)
      container.build_tag(self, with: [:ChildTag])
      container.build_childtag(self)
      container.build_join_table_model(self)
    end

    def test_preload_dependencies
      root_updates, ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes([{ '_type' => 'Parent' }])
      assert_equal(DeepPreloader::Spec.new,
                   root_updates.first.preload_dependencies(ref_updates),
                   'nothing loaded by default')

      root_updates, ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes(
        [{ '_type' => 'Parent',
           'tags' => [{ '_ref' => 'r1' }] }],
        { 'r1' => { '_type' => 'Tag', 'child_tags' => [] } })

      assert_equal(DeepPreloader::Spec.new('parents_tags' => DeepPreloader::Spec.new('tag' => DeepPreloader::Spec.new('child_tags' => DeepPreloader::Spec.new))),
                   root_updates.first.preload_dependencies(ref_updates),
                   'mentioning tags and child_tags causes through association loading')
    end

    def test_updated_associations
      root_updates, ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes(
        [{ '_type' => 'Parent',
           'tags' => [{ '_ref' => 'r1' }] }],
        { 'r1' => { '_type' => 'Tag', 'child_tags' => [] } })

      assert_equal({ 'tags' => { 'child_tags' => {} } },
                   root_updates.first.updated_associations(ref_updates),
                   'mentioning tags causes through association loading')

    end
  end
end
