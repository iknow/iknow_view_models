# frozen_string_literal: true

require_relative '../../../helpers/arvm_test_utilities'
require_relative '../../../helpers/arvm_test_models'
require_relative '../../../helpers/viewmodel_spec_helpers'

require 'minitest/autorun'

require 'view_model/active_record'

class ViewModel::ActiveRecord::HasOneTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  extend Minitest::Spec::DSL
  include ViewModelSpecHelpers::ParentAndHasOneChild

  def setup
    super

    # TODO: make a `has_list?` that allows a model to set all children as an array
    @model1 = model_class.new(name: 'p1',
                          child: child_model_class.new(name: 'p1t'))
    @model1.save!

    @model2 = model_class.new(name: 'p2',
                          child: child_model_class.new(name: 'p2t'))

    @model2.save!

    enable_logging!
  end

  def test_loading_batching
    log_queries do
      serialize(ModelView.load)
    end
    assert_equal(['Model Load', 'Child Load'],
                 logged_load_queries)
  end

  def test_create_from_view
    view = {
      '_type'    => 'Model',
      'name'     => 'p',
      'child' => { '_type' => 'Child', 'name' => 't' },
    }

    pv = ModelView.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal('p', p.name)

    assert(p.child.present?)
    assert_equal('t', p.child.name)
  end

  def test_serialize_view
    view, _refs = serialize_with_references(ModelView.new(@model1))
    assert_equal({ '_type'    => 'Model',
                   '_version' => 1,
                   'id'       => @model1.id,
                   'name'     => @model1.name,
                   'child' => { '_type' => 'Child',
                                   '_version' => 1,
                                   'id'       => @model1.child.id,
                                   'name'     => @model1.child.name } },
                 view)
  end

  def test_swap_has_one
    @model1.update(child: t1 = Child.new)
    @model2.update(child: t2 = Child.new)

    deserialize_context = ViewModelBase.new_deserialize_context

    ModelView.deserialize_from_view(
      [update_hash_for(ModelView, @model1) { |p| p['child'] = update_hash_for(ChildView, t2) },
       update_hash_for(ModelView, @model2) { |p| p['child'] = update_hash_for(ChildView, t1) },],
      deserialize_context: deserialize_context)

    assert_equal(Set.new([ViewModel::Reference.new(ModelView, @model1.id),
                          ViewModel::Reference.new(ModelView, @model2.id),]),
                 deserialize_context.valid_edit_refs.to_set)

    @model1.reload
    @model2.reload

    assert_equal(@model1.child, t2)
    assert_equal(@model2.child, t1)
  end

  def test_has_one_create_nil
    view = { '_type' => 'Model', 'name' => 'p', 'child' => nil }
    pv = ModelView.deserialize_from_view(view)
    assert_nil(pv.model.child)
  end

  def test_has_one_create
    @model1.update(child: nil)

    alter_by_view!(ModelView, @model1) do |view, refs|
      view['child'] = { '_type' => 'Child', 'name' => 't' }
    end

    assert_equal('t', @model1.child.name)
  end

  def test_has_one_update
    alter_by_view!(ModelView, @model1) do |view, refs|
      view['child']['name'] = 'hello'
    end

    assert_equal('hello', @model1.child.name)
  end

  def test_has_one_destroy
    old_child = @model1.child
    alter_by_view!(ModelView, @model1) do |view, refs|
      view['child'] = nil
    end
    assert(Child.where(id: old_child.id).blank?)
  end

  def test_has_one_move_and_replace
    old_model1_child = @model1.child
    old_model2_child = @model2.child

    alter_by_view!(ModelView, [@model1, @model2]) do |(p1, p2), refs|
      p2['child'] = p1['child']
      p1['child'] = nil
    end

    assert(@model1.child.blank?)
    assert_equal(old_model1_child, @model2.child)
    assert(Child.where(id: old_model2_child).blank?)
  end

  def test_has_one_cannot_duplicate_unreleased_child
    # p2 shouldn't be able to copy p1's child
    assert_raises(ViewModel::DeserializationError::DuplicateNodes) do
      alter_by_view!(ModelView, [@model1, @model2]) do |(p1, p2), _refs|
        p2['child'] = p1['child'].dup
      end
    end
  end

  def test_has_one_cannot_duplicate_implicitly_unreleased_child
    # p2 shouldn't be able to copy p1's child, even when p1 doesn't explicitly
    # specify the association
    assert_raises(ViewModel::DeserializationError::ParentNotFound) do
      alter_by_view!(ModelView, [@model1, @model2]) do |(p1, p2), _refs|
        p2['child'] = p1['child']
        p1.delete('child')
      end
    end
  end

  def test_has_one_cannot_take_from_outside_tree
    t3 = Model.create(child: Child.new(name: 'hi')).child

    assert_raises(ViewModel::DeserializationError::ParentNotFound) do
      alter_by_view!(ModelView, [@model1]) do |(p1), _refs|
        p1['child'] = update_hash_for(ChildView, t3)
      end
    end
  end

  def test_has_one_cannot_take_unmodeled_from_outside_tree
    t3 = Child.create(name: 'hi') # no model

    assert_raises(ViewModel::DeserializationError::ParentNotFound) do
      alter_by_view!(ModelView, @model1) do |p1, _refs|
        p1['child'] = update_hash_for(ChildView, t3)
      end
    end
  end

  def test_bad_single_association
    view = {
      '_type' => 'Model',
      'child' => [],
    }
    ex = assert_raises(ViewModel::DeserializationError::InvalidSyntax) do
      ModelView.deserialize_from_view(view)
    end
    assert_match(/not an object/, ex.message)
  end

  describe 'owned reference child' do
    def child_attributes
      super.merge(viewmodel: ->(v) { root! })
    end

    def new_model
      model_class.new(name: 'm1', child: child_model_class.new(name: 'c1'))
    end

    it 'makes a reference association' do
      assert(subject_association.referenced?)
    end

    it 'makes an owned association' do
      assert(subject_association.owned?)
    end

    it 'loads and batches' do
      create_model!

      log_queries do
        serialize(ModelView.load)
      end

      assert_equal(['Model Load', 'Child Load'], logged_load_queries)
    end

    it 'serializes' do
      model = create_model!
      view, refs = serialize_with_references(ModelView.new(model))
      child1_ref = refs.detect { |_, v| v['_type'] == 'Child' }.first

      assert_equal({ child1_ref => { '_type'    => 'Child',
                                     '_version' => 1,
                                     'id'       => model.child.id,
                                     'name'     => model.child.name } },
                   refs)

      assert_equal({ '_type'    => 'Model',
                     '_version' => 1,
                     'id'       => model.id,
                     'name'     => model.name,
                     'child' => { '_ref' => child1_ref } },
                   view)
    end

    it 'creates from view' do
      view = {
        '_type' => 'Model',
        'name'  => 'p',
        'child' => { '_ref' => 'r1' },
      }

      refs = {
        'r1' => { '_type' => 'Child', 'name' => 'newkid' },
      }

      pv = ModelView.deserialize_from_view(view, references: refs)
      p = pv.model

      assert(!p.changed?)
      assert(!p.new_record?)

      assert_equal('p', p.name)

      assert(p.child.present?)
      assert_equal('newkid', p.child.name)
    end

    it 'updates' do
      model = create_model!

      alter_by_view!(ModelView, model) do |view, refs|
        ref = view['child']['_ref']
        refs[ref]['name'] = 'newchildname'
      end

      assert_equal('newchildname', model.child.name)
    end

    describe 'without a child' do
      let(:new_model) {
        model_class.new(name: 'm1', child: nil)
      }

      it 'can add a child' do
        model = create_model!

        alter_by_view!(ModelView, model) do |view, refs|
          view['child'] = { '_ref' => 'ref1' }
          refs['ref1'] = {
            '_type' => 'Child',
            'name' => 'newchildname',
          }
        end

        assert(model.child.present?)
        assert_equal('newchildname', model.child.name)
      end
    end

    it 'replaces a child with a new child' do
      model = create_model!
      old_child = model.child

      alter_by_view!(ModelView, model) do |view, refs|
        ref = view['child']['_ref']
        refs[ref] = { '_type' => 'Child', 'name' => 'newchildname' }
      end
      model.reload

      assert_equal('newchildname', model.child.name)
      refute_equal(old_child, model.child)
      assert(Child.where(id: old_child.id).blank?)
    end

    it 'takes a released child from another parent' do
      model1 = create_model!
      model2 = create_model!

      old_child1 = model1.child
      old_child2 = model2.child

      alter_by_view!(ModelView, [model1, model2]) do |(view1, view2), refs|
        ref1 = view1['child']['_ref']
        ref2 = view2['child']['_ref']
        refs.delete(ref1)
        view1['child'] = { '_ref' => ref2 }
        view2['child'] = nil
      end

      assert_equal(model1.child, old_child2)
      assert_nil(model2.child)
      assert(Child.where(id: old_child1.id).blank?)
    end

    it 'prevents taking an unreleased reference out-of-tree' do
      model1 = create_model!
      child2 = Child.create!(name: 'dummy')

      assert_raises(ViewModel::DeserializationError::ParentNotFound) do
        alter_by_view!(ModelView, model1) do |view, refs|
          refs.clear
          view['child']['_ref'] = 'r1'
          refs['r1'] = { '_type' => 'Child', 'id' => child2.id }
        end
      end
    end

    it 'prevents taking an unreleased reference in-tree' do
      model1 = create_model!
      model2 = create_model!

      assert_raises(ViewModel::DeserializationError::DuplicateOwner) do
        alter_by_view!(ModelView, [model1, model2]) do |(view1, view2), refs|
          refs.delete(view1['child']['_ref'])
          view1['child']['_ref'] = view2['child']['_ref']
        end
      end
    end

    it 'prevents two parents taking the same new reference' do
      model1 = create_model!
      model2 = create_model!

      assert_raises(ViewModel::DeserializationError::DuplicateOwner) do
        alter_by_view!(ModelView, [model1, model2]) do |(view1, view2), refs|
          refs.clear
          refs['ref1'] = { '_type' => 'Child', 'name' => 'new' }
          view1['child']['_ref'] = 'ref1'
          view2['child']['_ref'] = 'ref1'
        end
      end
    end

    it 'swaps children' do
      model1 = create_model!
      model2 = create_model!

      old_child1 = model1.child
      old_child2 = model2.child

      alter_by_view!(ModelView, [model1, model2]) do |(view1, view2), _refs|
        ref1 = view1['child']
        ref2 = view2['child']
        view1['child'] = ref2
        view2['child'] = ref1
      end

      assert_equal(model1.child, old_child2)
      assert_equal(model2.child, old_child1)
    end

    it 'deletes a child' do
      model = create_model!
      old_child = model.child

      alter_by_view!(ModelView, model) do |view, refs|
        refs.clear
        view['child'] = nil
      end

      assert_nil(model.child)
      assert(Child.where(id: old_child.id).blank?)
    end

    it 'eager includes' do
      includes = viewmodel_class.eager_includes
      assert_equal(DeepPreloader::Spec.new('child' => DeepPreloader::Spec.new), includes)
    end
  end

  describe 'renaming associations' do
    def subject_association_features
      { as: :something_else }
    end

    def setup
      super

      @model = model_class.create(child: child_model_class.new(name: 'child name'))

      enable_logging!
    end

    def test_dependencies
      root_updates, _ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes([{ '_type' => 'Model', 'something_else' => nil }])
      assert_equal(DeepPreloader::Spec.new('child' => DeepPreloader::Spec.new), root_updates.first.preload_dependencies)
    end

    def test_renamed_roundtrip
      alter_by_view!(ModelView, @model) do |view, refs|
        assert_equal({ 'id'       => @model.child.id,
                       '_type'    => 'Child',
                       '_version' => 1,
                       'name'     => 'child name' },
                     view['something_else'])
        view['something_else']['name'] = 'child new name'
      end

      assert_equal('child new name', @model.child.name)
    end
  end

  class FreedChildrenTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      build_viewmodel(:Aye) do
        define_schema do |t|
          t.references :bee
        end
        define_model do
          belongs_to :bee, inverse_of: :aye, dependent: :destroy
        end
        define_viewmodel do
          association :bee
        end
      end

      build_viewmodel(:Bee) do
        define_schema do |t|
        end
        define_model do
          has_one :aye, inverse_of: :bee
          has_one :cee, inverse_of: :bee, dependent: :destroy
        end
        define_viewmodel do
          association :cee
        end
      end

      build_viewmodel(:Cee) do
        define_schema do |t|
          t.references :bee
        end
        define_model do
          belongs_to :bee, inverse_of: :cee
        end
        define_viewmodel do
        end
      end
    end

    def test_reclaim_grandchild_from_deleted_child
      skip 'Issue #8'

      model = Aye.create(bee: Bee.new(cee: Cee.new))

      # This test currently fails because we only release the top of the deleted
      # subtree to the release pool, and so its children cannot be reclaimed.
      alter_by_view!(AyeView, model) do |view, _refs|
        view['bee'].delete('id')
      end
    end
  end
end
