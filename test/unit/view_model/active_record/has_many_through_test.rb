# frozen_string_literal: true

require_relative '../../../helpers/arvm_test_utilities'
require_relative '../../../helpers/arvm_test_models'

require 'minitest/autorun'

require 'view_model/active_record'

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
        root!
        attributes :name
        association :tags, through: :parents_tags, through_order_attr: :position
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
        root!
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
        # TODO: list membership?
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

  def setup
    super

    @tag1, @tag2, @tag3 = (1..3).map { |x| Tag.create!(name: "tag#{x}") }

    @parent1 = Parent.create(name: 'p1',
                             parents_tags: [
                               ParentsTag.new(tag: @tag2, position: 2.0),
                               ParentsTag.new(tag: @tag1, position: 1.0),
                             ])

    enable_logging!
  end

  def test_loading_batching
    context = ParentView.new_serialize_context
    log_queries do
      parent_views = ParentView.load
      serialize(parent_views, serialize_context: context)
    end

    assert_equal(['Parent Load', 'ParentsTag Load', 'Tag Load'],
                 logged_load_queries)
  end

  def test_roundtrip
    # Objects are serialized to a view and deserialized, and should not be different when complete.

    alter_by_view!(ParentView, @parent1) {}
    assert_equal('p1', @parent1.name)
    assert_equal([@tag1, @tag2], @parent1.parents_tags.order(:position).map(&:tag))
  end

  def test_eager_includes
    includes = ParentView.eager_includes
    assert_equal(DeepPreloader::Spec.new('parents_tags' => DeepPreloader::Spec.new('tag' => DeepPreloader::Spec.new)), includes)
  end

  def test_preload_dependencies
    # TODO: not part of ARVM; but depends on the particular context from #before_all
    # If we refactor out the contexts from their tests, this should go in another test file.

    root_updates, _ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes([{ '_type' => 'Parent' }])
    assert_equal(DeepPreloader::Spec.new,
                 root_updates.first.preload_dependencies,
                 'nothing loaded by default')

    root_updates, _ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes(
      [{ '_type' => 'Parent',
         'tags' => [{ '_ref' => 'r1' }] }],
      { 'r1' => { '_type' => 'Tag' } })

    assert_equal(DeepPreloader::Spec.new('parents_tags' => DeepPreloader::Spec.new('tag' => DeepPreloader::Spec.new)),
                 root_updates.first.preload_dependencies,
                 'mentioning tags and child_tags causes through association loading')
  end

  def test_serialize
    view, refs = serialize_with_references(ParentView.new(@parent1))

    tag_data = view['tags'].map { |hash| refs[hash['_ref']] }
    assert_equal([{ 'id' => @tag1.id, '_type' => 'Tag', '_version' => 1, 'name' => 'tag1' },
                  { 'id' => @tag2.id, '_type' => 'Tag', '_version' => 1, 'name' => 'tag2' },],
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
    pv, ctx = alter_by_view!(ParentView, @parent1) do |view, _refs|
      view['tags'].reverse!
    end

    assert_equal([@tag2, @tag1],
                 @parent1.parents_tags.order(:position).map(&:tag))

    expected_edit_checks = [pv.to_reference]
    assert_contains_exactly(expected_edit_checks, ctx.valid_edit_refs)
  end

  def test_child_edit_doesnt_editcheck_parent
    # editing child doesn't edit check parent
    pv, d_context = alter_by_view!(ParentView, @parent1) do |view, refs|
      refs[view['tags'][0]['_ref']]['name'] = 'changed'
    end

    nc = pv.tags.detect { |t| t.name == 'changed' }

    expected_edit_checks = [nc.to_reference]
    assert_contains_exactly(expected_edit_checks,
                            d_context.valid_edit_refs)
  end

  def test_child_reordering_editchecks_parent
    pv, d_context = alter_by_view!(ParentView, @parent1) do |view, _refs|
      view['tags'].reverse!
    end

    assert_contains_exactly([pv.to_reference],
                            d_context.valid_edit_refs)
  end

  def test_child_deletion_editchecks_parent
    pv, d_context = alter_by_view!(ParentView, @parent1) do |view, refs|
      removed = view['tags'].pop['_ref']
      refs.delete(removed)
    end

    assert_contains_exactly([pv.to_reference],
                            d_context.valid_edit_refs)
  end

  def test_child_addition_editchecks_parent
    pv, d_context = alter_by_view!(ParentView, @parent1) do |view, refs|
      view['tags'] << { '_ref' => 't_new' }
      refs['t_new'] = { '_type' => 'Tag', 'name' => 'newest tag' }
    end

    nc = pv.tags.detect { |t| t.name == 'newest tag' }

    expected_edit_checks = [pv.to_reference, nc.to_reference]

    assert_contains_exactly(expected_edit_checks,
                            d_context.valid_edit_refs)
  end

  def tags(parent)
    parent.parents_tags.order(:position).includes(:tag).map(&:tag)
  end

  def fupdate_tags(parent)
    tags          = self.tags(parent)
    fupdate, refs = yield(tags).values_at(:fupdate, :refs)
    op_view       = { '_type' => 'Parent',
                      'id'    => parent.id,
                      'tags'  => fupdate }
    ParentView.deserialize_from_view(op_view, references: refs || {})
    parent.reload
  end

  def test_functional_update_append
    c1 = c2 = nil
    fupdate_tags(@parent1) do |tags|
      c1, c2 = tags
      { :fupdate => build_fupdate { append([{ '_ref' => 'new_tag' }]) },
        :refs    => { 'new_tag' => { '_type' => 'Tag', 'name' => 'new tag' } },
      }
    end
    assert_equal([c1.name, c2.name, 'new tag'],
                 tags(@parent1).map(&:name))
  end

  def test_functional_update_append_before_mid
    c1 = c2 = nil
    fupdate_tags(@parent1) do |tags|
      c1, c2 = tags
      { :fupdate => build_fupdate { append([{ '_ref' => 'new_tag' }],
                                           before: { '_type' => 'Tag', 'id' => c2.id }) },
        :refs    => { 'new_tag' => { '_type' => 'Tag', 'name' => 'new tag' } },
      }
    end
    assert_equal([c1.name, 'new tag', c2.name],
                 tags(@parent1).map(&:name))
  end

  def test_functional_update_append_before_beginning
    c1 = c2 = nil
    fupdate_tags(@parent1) do |tags|
      c1, c2 = tags
      { :fupdate => build_fupdate { append([{ '_ref' => 'new_tag' }],
                                           before: { '_type' => 'Tag', 'id' => c1.id }) },
        :refs    => { 'new_tag' => { '_type' => 'Tag', 'name' => 'new tag' } },
      }
    end
    assert_equal(['new tag', c1.name, c2.name],
                 tags(@parent1).map(&:name))
  end

  def test_functional_update_append_before_reorder
    c1 = c2 = nil
    fupdate_tags(@parent1) do |tags|
      c1, c2 = tags
      { :fupdate => build_fupdate { append([{ '_ref' => 'c2' }],
                                           before: { '_type' => 'Tag', 'id' => c1.id }) },
        :refs    => { 'c2' => { '_type' => 'Tag', 'id' => c2.id } },
      }
    end
    assert_equal([c2.name, c1.name],
                 tags(@parent1).map(&:name))
  end

  def test_functional_update_append_after_mid
    c1 = c2 = nil
    fupdate_tags(@parent1) do |tags|
      c1, c2 = tags
      { :fupdate => build_fupdate { append([{ '_ref' => 'new_tag' }],
                                           after: { '_type' => 'Tag', 'id' => c1.id }) },
        :refs    => { 'new_tag' => { '_type' => 'Tag', 'name' => 'new tag' } },
      }
    end
    assert_equal([c1.name, 'new tag', c2.name],
                 tags(@parent1).map(&:name))
  end

  def test_functional_update_append_after_end
    c1 = c2 = nil
    fupdate_tags(@parent1) do |tags|
      c1, c2 = tags
      { :fupdate => build_fupdate { append([{ '_ref' => 'new_tag' }],
                                           after: { '_type' => 'Tag', 'id' => c2.id }) },
        :refs    => { 'new_tag' => { '_type' => 'Tag', 'name' => 'new tag' } },
      }
    end
    assert_equal([c1.name, c2.name, 'new tag'],
                 tags(@parent1).map(&:name))
  end

  def test_functional_update_append_after_reorder
    c1 = c2 = nil
    fupdate_tags(@parent1) do |tags|
      c1, c2 = tags
      { :fupdate => build_fupdate { append([{ '_ref' => 'c1' }],
                                           after: { '_type' => 'Tag', 'id' => c2.id }) },
        :refs    => { 'c1' => { '_type' => 'Tag', 'id' => c1.id } },
      }
    end
    assert_equal([c2.name, c1.name],
                 tags(@parent1).map(&:name))
  end

  def test_functional_update_remove_success
    c1 = c2 = nil
    fupdate_tags(@parent1) do |tags|
      c1, c2 = tags
      { :fupdate => build_fupdate { remove([{ '_type' => 'Tag', 'id' => c1.id }]) } }
    end
    assert_equal([c2.name],
                 tags(@parent1).map(&:name))
  end

  def test_functional_update_remove_stale
    # remove an entity that's no longer part of the collection
    ex = assert_raises(ViewModel::DeserializationError::AssociatedNotFound) do
      fupdate_tags(@parent1) do |tags|
        _c1, c2 = tags
        @parent1.parents_tags.where(tag_id: c2.id).destroy_all
        { :fupdate => build_fupdate { remove([{ '_type' => 'Tag', 'id' => c2.id }]) } }
      end
    end
    assert_equal('tags', ex.association)
  end

  def test_functional_update_append_after_corpse
    # append after something that no longer exists
    ex = assert_raises(ViewModel::DeserializationError::AssociatedNotFound) do
      fupdate_tags(@parent1) do |tags|
        _c1, c2 = tags
        @parent1.parents_tags.where(tag_id: c2.id).destroy_all
        { :fupdate => build_fupdate { append([{ '_ref' => 'new_tag' }],
                                             after: { '_type' => 'Tag', 'id' => c2.id }) },
          :refs    => { 'new_tag' => { '_type' => 'Tag', 'name' => 'new tag name' } },
        }
      end
    end
    assert_equal('tags', ex.association)
  end

  def test_functional_update_update_success
    # refer to a shared entity with edits, no collection add/remove
    c1 = c2 = nil
    fupdate_tags(@parent1) do |tags|
      c1, c2 = tags
      { :fupdate => build_fupdate { update([{ '_ref' => 'c1' }]) },
        :refs    => { 'c1' => { '_type' => 'Tag', 'id' => c1.id, 'name' => 'c1 new name' } },
      }
    end
    assert_equal(['c1 new name', c2.name],
                 tags(@parent1).map(&:name))
  end

  def test_functional_update_update_stale
    _c1, c2 = tags(@parent1)

    # update for a shared entity that's no longer present in the association
    c2.parents_tags.destroy_all

    ex = assert_raises(ViewModel::DeserializationError::AssociatedNotFound) do
      fupdate_tags(@parent1) do |_tags|
        { :fupdate => build_fupdate { update([{ '_ref' => 'c2' }]) },
          :refs    => { 'c2' => { '_type' => 'Tag', 'id' => c2.id, 'name' => 'c2 new name' } },
        }
      end
    end
    assert_equal('tags', ex.association)
    assert_equal([ViewModel::Reference.new(TagView, c2.id)], ex.missing_nodes)
  end

  def test_functional_update_edit_checks
    fupdate = build_fupdate do
      append([{ '_ref' => 't_new' }])
    end

    view = { '_type' => 'Parent',
             'id'    => @parent1.id,
             'tags'  => fupdate }

    refs = { 't_new' => { '_type' => 'Tag', 'name' => 'newest tag' } }

    d_context = ParentView.new_deserialize_context
    pv = ParentView.deserialize_from_view(view, references: refs, deserialize_context: d_context)
    new_tag = pv.tags.detect { |t| t.name == 'newest tag' }

    expected_edit_checks = [pv.to_reference, new_tag.to_reference]
    assert_contains_exactly(expected_edit_checks, d_context.valid_edit_refs)
  end

  def test_replace_associated
    pv = ParentView.new(@parent1)
    context = ParentView.new_deserialize_context

    data = [{ ViewModel::REFERENCE_ATTRIBUTE => 'tag1' }]
    references = { 'tag1' => { '_type' => 'Tag', 'name' => 'new_tag' } }

    updated = pv.replace_associated(:tags,
      data, references: references,
      deserialize_context: context)

    post_children = ParentView.new(Parent.find(@parent1.id))._read_association(:tags)

    expected_edit_checks = [pv.to_reference,
                            *post_children.map(&:to_reference),]

    assert_contains_exactly(expected_edit_checks,
                            context.valid_edit_refs)

    assert_equal(1, updated.size)
    assert(updated[0].is_a?(TagView))
    assert_equal('new_tag', updated[0].name)

    @parent1.reload
    assert_equal(['new_tag'], tags(@parent1).map(&:name))
  end

  # Test that each of the functional updates actions work through
  # replace_associated. The main tests for functional updates are
  # earlier in this file.
  def test_replace_associated_functional
    pv = ParentView.new(@parent1)
    context = ParentView.new_deserialize_context

    tag1 = @tag1
    tag2 = @tag2

    update = build_fupdate do
      append([{ViewModel::REFERENCE_ATTRIBUTE => 'ref_new_tag'}])
      remove([{ '_type' => 'Tag', 'id' => tag2.id }])
      update([{ViewModel::REFERENCE_ATTRIBUTE => 'ref_tag1'}])
    end

    references = {
      'ref_new_tag' => { '_type' => 'Tag', 'name' => 'new_tag' },
      'ref_tag1' => { '_type' => 'Tag', 'id' => tag1.id, 'name' => 'renamed tag1' },
    }

    updated = pv.replace_associated(:tags, update, references: references, deserialize_context: context)
    post_children = ParentView.new(Parent.find(@parent1.id))._read_association(:tags)
    new_tag = post_children.detect { |t| t.name == 'new_tag' }

    expected_edit_checks = [ViewModel::Reference.new(ParentView, @parent1.id),
                            ViewModel::Reference.new(TagView, @tag1.id),
                            ViewModel::Reference.new(TagView, new_tag.id),]

    assert_contains_exactly(expected_edit_checks,
                            context.valid_edit_refs)

    assert_equal(2, post_children.size)
    assert_equal(2, update.size)
    assert_contains_exactly(
      ['new_tag', 'renamed tag1'],
      updated.map(&:name),
    )

    @parent1.reload
    assert_equal(['renamed tag1', 'new_tag'], tags(@parent1).map(&:name))
  end

  def test_delete_associated_has_many
    t1, t2 = tags(@parent1)

    pv = ParentView.new(@parent1)
    context = ParentView.new_deserialize_context

    pv.delete_associated(:tags, t1.id,
                         deserialize_context: context)

    expected_edit_checks = [ViewModel::Reference.new(ParentView, @parent1.id)].to_set

    assert_equal(expected_edit_checks,
                 context.valid_edit_refs.to_set)

    @parent1.reload
    assert_equal([t2], tags(@parent1))
  end

  def test_append_associated_move_has_many
    pv = ParentView.new(@parent1)

    expected_edit_checks = [ViewModel::Reference.new(ParentView, @parent1.id)].to_set

    # insert before
    pv.append_associated(:tags,
                         { '_type' => 'Tag', 'id' => @tag2.id },
                         before: ViewModel::Reference.new(TagView, @tag1.id),
                         deserialize_context: (context = ParentView.new_deserialize_context))

    assert_equal(expected_edit_checks, context.valid_edit_refs.to_set)

    assert_equal([@tag2, @tag1],
                 tags(@parent1))

    # insert after
    pv.append_associated(:tags,
                         { '_type' => 'Tag', 'id' => @tag2.id },
                         after: ViewModel::Reference.new(TagView, @tag1.id),
                         deserialize_context: (context = ParentView.new_deserialize_context))

    assert_equal(expected_edit_checks, context.valid_edit_refs.to_set)

    assert_equal([@tag1, @tag2],
                 tags(@parent1))

    # append
    pv.append_associated(:tags,
                         { '_type' => 'Tag', 'id' => @tag1.id },
                         deserialize_context: ParentView.new_deserialize_context)

    assert_equal([@tag2, @tag1],
                 tags(@parent1))
  end

  def test_append_associated_insert_has_many
    pv = ParentView.new(@parent1)

    expected_edit_checks = [ViewModel::Reference.new(ParentView, @parent1.id)].to_set

    # insert before
    pv.append_associated(:tags,
                         { '_type' => 'Tag', 'id' => @tag3.id },
                         before: ViewModel::Reference.new(TagView, @tag1.id),
                         deserialize_context: (context = ParentView.new_deserialize_context))

    assert_equal(expected_edit_checks, context.valid_edit_refs.to_set)

    assert_equal([@tag3, @tag1, @tag2],
                 tags(@parent1))

    @parent1.parents_tags.where(tag_id: @tag3.id).destroy_all

    # insert after
    pv.append_associated(:tags,
                         { '_type' => 'Tag', 'id' => @tag3.id },
                         after: ViewModel::Reference.new(TagView, @tag1.id),
                         deserialize_context: (context = ParentView.new_deserialize_context))

    assert_equal(expected_edit_checks, context.valid_edit_refs.to_set)

    assert_equal([@tag1, @tag3, @tag2],
                 tags(@parent1))

    @parent1.parents_tags.where(tag_id: @tag3.id).destroy_all

    # append
    pv.append_associated(:tags,
                         { '_type' => 'Tag', 'id' => @tag3.id },
                         deserialize_context: ParentView.new_deserialize_context)

    assert_equal([@tag1, @tag2, @tag3],
                 tags(@parent1))
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
          root!
          attributes :name
          association :tags, through: :parents_tags, through_order_attr: :position, as: :something_else
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
      root_updates, _ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes([{ '_type' => 'Parent', 'something_else' => [] }])
      assert_equal(DeepPreloader::Spec.new('parents_tags' => DeepPreloader::Spec.new('tag' => DeepPreloader::Spec.new)),
                   root_updates.first.preload_dependencies)
    end

    def test_renamed_roundtrip
      context = ParentView.new_serialize_context
      alter_by_view!(ParentView, @parent, serialize_context: context) do |view, refs|
        assert_equal({ refs.keys.first => { 'id' => @parent.parents_tags.first.tag.id,
                                           '_type'    => 'Tag',
                                           '_version' => 1,
                                           'name'     => 'tag name' } }, refs)
        assert_equal([{ '_ref' => refs.keys.first }],
                     view['something_else'])

        refs.clear
        refs['new'] = { '_type' => 'Tag', 'name' => 'tag new name' }
        view['something_else'] = [{ '_ref' => 'new' }]
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
      root_updates, _ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes([{ '_type' => 'Parent' }])
      assert_equal(DeepPreloader::Spec.new,
                   root_updates.first.preload_dependencies,
                   'nothing loaded by default')

      root_updates, _ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes(
        [{ '_type' => 'Parent',
           'tags' => [{ '_ref' => 'r1' }] }],
        { 'r1' => { '_type' => 'Tag', 'child_tags' => [] } })

      assert_equal(DeepPreloader::Spec.new('parents_tags' => DeepPreloader::Spec.new('tag' => DeepPreloader::Spec.new)),
                   root_updates.first.preload_dependencies,
                   'mentioning tags and child_tags causes through association loading, excluding shared')
    end

    def test_preload_dependencies_functional
      fupdate = build_fupdate do
        append([{ '_ref' => 'r1' }])
      end

      root_updates, _ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes(
        [{ '_type' => 'Parent',
           'tags'  => fupdate }],
        { 'r1' => { '_type' => 'Tag', 'child_tags' => [] } })

      assert_equal(DeepPreloader::Spec.new('parents_tags' => DeepPreloader::Spec.new('tag' => DeepPreloader::Spec.new)),
                   root_updates.first.preload_dependencies,
                   'mentioning tags and child_tags in functional update value causes through association loading, ' \
                   'excluding shared')
    end
  end
end
