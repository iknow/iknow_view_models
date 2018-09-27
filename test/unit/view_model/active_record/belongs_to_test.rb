require_relative "../../../helpers/arvm_test_utilities.rb"
require_relative "../../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "view_model/active_record"

class ViewModel::ActiveRecord::BelongsToTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  module WithLabel
    def before_all
      super

      build_viewmodel(:Label) do
        define_schema do |t|
          t.string :text
        end

        define_model do
          has_one :parent, inverse_of: :label
        end

        define_viewmodel do
          attributes :text
        end
      end
    end
  end

  module WithParent
    def before_all
      super

      build_viewmodel(:Parent) do
        define_schema do |t|
          t.string :name
          t.references :label, foreign_key: true
        end

        define_model do
          belongs_to :label, inverse_of: :parent, dependent: :destroy
        end

        define_viewmodel do
          attributes   :name
          associations :label
        end
      end
    end
  end

  module WithOwner
    def before_all
      super

      build_viewmodel(:Owner) do
        define_schema do |t|
          t.integer :deleted_id
          t.integer :ignored_id
        end

        define_model do
          belongs_to :deleted, class_name: Label.name, dependent: :delete
          belongs_to :ignored, class_name: Label.name
        end

        define_viewmodel do
          associations :deleted, :ignored
        end
      end
    end
  end

  include WithLabel
  include WithParent

  def setup
    super

    # TODO make a `has_list?` that allows a parent to set all children as an array
    @parent1 = Parent.new(name: "p1",
                          label: Label.new(text: "p1l"))
    @parent1.save!

    @parent2 = Parent.new(name: "p2",
                          label: Label.new(text: "p2l"))

    @parent2.save!

    enable_logging!
  end

  def test_serialize_view
    view, _refs = serialize_with_references(ParentView.new(@parent1))

    assert_equal({ "_type"    => "Parent",
                   "_version" => 1,
                   "id"       => @parent1.id,
                   "name"     => @parent1.name,
                   "label"    => { "_type"    => "Label",
                                   "_version" => 1,
                                   "id"       => @parent1.label.id,
                                   "text"     => @parent1.label.text },
                 },
                 view)
  end

  def test_loading_batching
    log_queries do
      serialize(ParentView.load)
    end

    assert_equal(['Parent Load', 'Label Load'],
                 logged_load_queries)
  end

  def test_create_from_view
    view = {
      "_type"    => "Parent",
      "name"     => "p",
      "label"    => { "_type" => "Label", "text" => "l" },
    }

    pv = ParentView.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal("p", p.name)

    assert(p.label.present?)
    assert_equal("l", p.label.text)
  end

  def test_create_belongs_to_nil
    view = { '_type' => 'Parent', 'name' => 'p', 'label' => nil }
    pv = ParentView.deserialize_from_view(view)
    assert_nil(pv.model.label)
  end

  def test_create_invalid_child_type
    view = { '_type' => 'Parent', 'name' => 'p', 'label' => { '_type' => 'Parent', 'name' => 'q' } }
    assert_raises(ViewModel::DeserializationError::InvalidAssociationType) do
      ParentView.deserialize_from_view(view)
    end
  end

  def test_belongs_to_create
    @parent1.update(label: nil)

    alter_by_view!(ParentView, @parent1) do |view, refs|
      view['label'] = { '_type' => 'Label', 'text' => 'cheese' }
    end

    assert_equal('cheese', @parent1.label.text)
  end

  def test_belongs_to_replace
    old_label = @parent1.label

    alter_by_view!(ParentView, @parent1) do |view, refs|
      view['label'] = { '_type' => 'Label', 'text' => 'cheese' }
    end

    assert_equal('cheese', @parent1.label.text)
    assert(Label.where(id: old_label).blank?)
  end

  def test_belongs_to_move_and_replace
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    set_by_view!(ParentView, [@parent1, @parent2]) do |(p1, p2), refs|
      p1['label'] = nil
      p2['label'] = update_hash_for(LabelView, old_p1_label)
    end

    assert(@parent1.label.blank?, 'l1 label reference removed')
    assert_equal(old_p1_label, @parent2.label, 'p2 has label from p1')
    assert(Label.where(id: old_p2_label).blank?, 'p2 old label deleted')
  end

  def test_belongs_to_swap
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    alter_by_view!(ParentView, [@parent1, @parent2]) do |(p1, p2), refs|
      p1['label'] = update_hash_for(LabelView, old_p2_label)
      p2['label'] = update_hash_for(LabelView, old_p1_label)
    end

    assert_equal(old_p2_label, @parent1.label, 'p1 has label from p2')
    assert_equal(old_p1_label, @parent2.label, 'p2 has label from p1')
  end


  def test_moved_child_is_not_delete_checked
    # move from p1 to p3
    d_context = ParentView.new_deserialize_context

    target_label = Label.create
    from_parent  = Parent.create(name: 'from', label: target_label)
    to_parent    = Parent.create(name: 'p3')

    alter_by_view!(
      ParentView, [from_parent, to_parent],
      deserialize_context: d_context
    ) do |(from, to), refs|
      from['label'] = nil
      to['label']   = update_hash_for(LabelView, target_label)
    end

    assert_equal(target_label, to_parent.label, 'target label moved')
    assert_equal([ViewModel::Reference.new(ParentView, from_parent.id),
                  ViewModel::Reference.new(ParentView, to_parent.id)],
                 d_context.valid_edit_refs,
                 "only parents are checked for change; child was not")
  end

  def test_implicit_release_invalid_belongs_to
    taken_label_ref = update_hash_for(LabelView, @parent1.label)
    assert_raises(ViewModel::DeserializationError::ParentNotFound) do
      ParentView.deserialize_from_view(
        [{ '_type' => 'Parent',
           'name'  => 'newp',
           'label' => taken_label_ref }])
    end
  end

  class GCTests < ActiveSupport::TestCase
    include ARVMTestUtilities
    include WithLabel
    include WithOwner
    include WithParent

    # test belongs_to garbage collection - dependent: delete_all
    def test_gc_dependent_delete_all
      owner = Owner.create(deleted: Label.new(text: 'one'))
      old_label = owner.deleted

      alter_by_view!(OwnerView, owner) do |ov, refs|
        ov['deleted'] = { '_type' => 'Label', 'text' => 'two' }
      end

      assert_equal('two', owner.deleted.text)
      refute_equal(old_label, owner.deleted)
      assert(Label.where(id: old_label.id).blank?)
    end

    def test_no_gc_dependent_ignore
      owner = Owner.create(ignored: Label.new(text: "one"))
      old_label = owner.ignored

      alter_by_view!(OwnerView, owner) do |ov, refs|
        ov['ignored'] = { '_type' => 'Label', 'text' => 'two' }
      end
      assert_equal('two', owner.ignored.text)
      refute_equal(old_label, owner.ignored)
      assert_equal(1, Label.where(id: old_label.id).count)
    end
  end

  class RenamedTest < ActiveSupport::TestCase
    include ARVMTestUtilities
    include WithLabel

    def before_all
      super

      build_viewmodel(:Parent) do
        define_schema do |t|
          t.string :name
          t.references :label, foreign_key: true
        end

        define_model do
          belongs_to :label, inverse_of: :parent, dependent: :destroy
        end

        define_viewmodel do
          attributes :name
          association :label, as: :something_else
        end
      end
    end

    def setup
      super

      @parent = Parent.create(name: 'p1', label: Label.new(text: 'l1'))

      enable_logging!
    end

    def test_dependencies
      root_updates, _ref_updates = ViewModel::ActiveRecord::UpdateData.parse_hashes([{ '_type' => 'Parent', 'something_else' => nil }])
      assert_equal(DeepPreloader::Spec.new('label' => DeepPreloader::Spec.new), root_updates.first.preload_dependencies)
      assert_equal({ 'something_else' => {} }, root_updates.first.updated_associations)
    end

    def test_renamed_roundtrip
      alter_by_view!(ParentView, @parent) do |view, refs|
        assert_equal({ 'id'       => @parent.label.id,
                       '_type'    => 'Label',
                       '_version' => 1,
                       'text'     => 'l1' },
                     view['something_else'])
        view['something_else']['text'] = 'new l1 text'
      end
      assert_equal('new l1 text', @parent.label.text)
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


    # Do we support replacing a node in the tree and reparenting its children
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
          view['bee'].delete("id")
        end
      end
    end
  end
end
