require_relative '../../../helpers/arvm_test_utilities.rb'
require_relative '../../../helpers/arvm_test_models.rb'
require_relative '../../../helpers/viewmodel_spec_helpers.rb'

require 'minitest/autorun'

require 'view_model/active_record'

class ViewModel::ActiveRecord::BelongsToTest < ActiveSupport::TestCase
  include ARVMTestUtilities
  extend Minitest::Spec::DSL
  include ViewModelSpecHelpers::ParentAndBelongsToChild

  def setup
    super

    # TODO make a `has_list?` that allows a parent to set all children as an array
    @model1 = model_class.new(name: 'p1',
                              child: child_model_class.new(name: 'p1l'))
    @model1.save!

    @model2 = model_class.new(name: 'p2',
                              child: child_model_class.new(name: 'p2l'))

    @model2.save!

    enable_logging!
  end

  def test_serialize_view
    view, _refs = serialize_with_references(ModelView.new(@model1))

    assert_equal({ '_type'    => 'Model',
                   '_version' => 1,
                   'id'       => @model1.id,
                   'name'     => @model1.name,
                   'child'    => { '_type'    => 'Child',
                                   '_version' => 1,
                                   'id'       => @model1.child.id,
                                   'name'     => @model1.child.name },
                 },
                 view)
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
      'child'    => { '_type' => 'Child', 'name' => 'l' },
    }

    pv = ModelView.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal('p', p.name)

    assert(p.child.present?)
    assert_equal('l', p.child.name)
  end

  def test_create_belongs_to_nil
    view = { '_type' => 'Model', 'name' => 'p', 'child' => nil }
    pv = ModelView.deserialize_from_view(view)
    assert_nil(pv.model.child)
  end

  def test_create_invalid_child_type
    view = { '_type' => 'Model', 'name' => 'p', 'child' => { '_type' => 'Model', 'name' => 'q' } }
    assert_raises(ViewModel::DeserializationError::InvalidAssociationType) do
      ModelView.deserialize_from_view(view)
    end
  end

  def test_belongs_to_create
    @model1.update(child: nil)

    alter_by_view!(ModelView, @model1) do |view, refs|
      view['child'] = { '_type' => 'Child', 'name' => 'cheese' }
    end

    assert_equal('cheese', @model1.child.name)
  end

  def test_belongs_to_replace
    old_child = @model1.child

    alter_by_view!(ModelView, @model1) do |view, refs|
      view['child'] = { '_type' => 'Child', 'name' => 'cheese' }
    end

    assert_equal('cheese', @model1.child.name)
    assert(Child.where(id: old_child).blank?)
  end

  def test_belongs_to_move_and_replace
    old_p1_child = @model1.child
    old_p2_child = @model2.child

    set_by_view!(ModelView, [@model1, @model2]) do |(p1, p2), refs|
      p1['child'] = nil
      p2['child'] = update_hash_for(ChildView, old_p1_child)
    end

    assert(@model1.child.blank?, 'l1 child reference removed')
    assert_equal(old_p1_child, @model2.child, 'p2 has child from p1')
    assert(Child.where(id: old_p2_child).blank?, 'p2 old child deleted')
  end

  def test_belongs_to_swap
    old_p1_child = @model1.child
    old_p2_child = @model2.child

    alter_by_view!(ModelView, [@model1, @model2]) do |(p1, p2), refs|
      p1['child'] = update_hash_for(ChildView, old_p2_child)
      p2['child'] = update_hash_for(ChildView, old_p1_child)
    end

    assert_equal(old_p2_child, @model1.child, 'p1 has child from p2')
    assert_equal(old_p1_child, @model2.child, 'p2 has child from p1')
  end

  def test_moved_child_is_not_delete_checked
    # move from p1 to p3
    d_context = ModelView.new_deserialize_context

    target_child = Child.create
    from_model  = Model.create(name: 'from', child: target_child)
    to_model    = Model.create(name: 'p3')

    alter_by_view!(
      ModelView, [from_model, to_model],
      deserialize_context: d_context
    ) do |(from, to), refs|
      from['child'] = nil
      to['child']   = update_hash_for(ChildView, target_child)
    end

    assert_equal(target_child, to_model.child, 'target child moved')
    assert_equal([ViewModel::Reference.new(ModelView, from_model.id),
                  ViewModel::Reference.new(ModelView, to_model.id)],
                 d_context.valid_edit_refs,
                 'only models are checked for change; child was not')
  end

  def test_implicit_release_invalid_belongs_to
    taken_child_ref = update_hash_for(ChildView, @model1.child)
    assert_raises(ViewModel::DeserializationError::ParentNotFound) do
      ModelView.deserialize_from_view(
        [{ '_type' => 'Model',
           'name'  => 'newp',
           'child' => taken_child_ref }])
    end
  end

  class GCTests < ActiveSupport::TestCase
    include ARVMTestUtilities
    include ViewModelSpecHelpers::ParentAndBelongsToChild

    def model_attributes
      super.merge(
        schema: ->(t) do
          t.integer :deleted_child_id
          t.integer :ignored_child_id
        end,
        model: ->(m) do
          belongs_to :deleted_child, class_name: Child.name, dependent: :delete
          belongs_to :ignored_child, class_name: Child.name
        end,
        viewmodel: ->(v) do
          associations :deleted_child, :ignored_child
        end)
    end

    # test belongs_to garbage collection - dependent: delete_all
    def test_gc_dependent_delete_all
      model = model_class.create(deleted_child: Child.new(name: 'one'))
      old_child = model.deleted_child

      alter_by_view!(ModelView, model) do |ov, _refs|
        ov['deleted_child'] = { '_type' => 'Child', 'name' => 'two' }
      end

      assert_equal('two', model.deleted_child.name)
      refute_equal(old_child, model.deleted_child)
      assert(Child.where(id: old_child.id).blank?)
    end

    def test_no_gc_dependent_ignore
      model = model_class.create(ignored_child: Child.new(name: 'one'))
      old_child = model.ignored_child

      alter_by_view!(ModelView, model) do |ov, _refs|
        ov['ignored_child'] = { '_type' => 'Child', 'name' => 'two' }
      end
      assert_equal('two', model.ignored_child.name)
      refute_equal(old_child, model.ignored_child)
      assert_equal(1, Child.where(id: old_child.id).count)
    end
  end

  class RenamedTest < ActiveSupport::TestCase
    include ARVMTestUtilities
    include ViewModelSpecHelpers::ParentAndBelongsToChild

    def subject_association_features
      { as: :something_else }
    end

    def setup
      super

      @model = model_class.create(name: 'p1', child: child_model_class.new(name: 'l1'))

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
                       'name'     => 'l1' },
                     view['something_else'])
        view['something_else']['name'] = 'new l1 name'
      end
      assert_equal('new l1 name', @model.child.name)
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
          t.references :cee
        end
        define_model do
          has_one :aye, inverse_of: :bee
          belongs_to :cee, inverse_of: :bee, dependent: :destroy
        end
        define_viewmodel do
          association :cee
        end
      end

      build_viewmodel(:Cee) do
        define_schema do |t|
        end
        define_model do
          has_one :bee, inverse_of: :cee
        end
        define_viewmodel do
        end
      end
    end


    # Do we support replacing a node in the tree and remodeling its children
    # back to it? In theory we want to, but currently we don't: the child node
    # is unresolvable.

    # To support it we could maintain a list of child elements that will be
    # implicitly freed by each freelist entry. Then worklist entries could
    # resolve themselves from these children, and nil out the association target
    # in the freelist to prevent them from being deleted when the freelist is
    # cleaned. If the freelist entry is subsequently reclaimed, double update
    # protection should prevent the child from being reused, but that will need
    # testing.
    def test_move
      model = Aye.create(bee: Bee.new(cee: Cee.new))
      assert_raises(ViewModel::DeserializationError::ParentNotFound) do
        alter_by_view!(AyeView, model) do |view, refs|
          view['bee'].delete('id')
        end
      end
    end
  end
end
