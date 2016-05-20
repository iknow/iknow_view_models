require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

class ActiveRecordViewModel::BelongsToTest < ActiveSupport::TestCase
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
          include TrivialAccessControl
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
          include TrivialAccessControl
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
          include TrivialAccessControl
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
    view, _refs = serialize_with_references(Views::Parent.new(@parent1))

    assert_equal({ "_type" => "Parent",
                   "id" => @parent1.id,
                   "name" => @parent1.name,
                   "label" => { "_type" => "Label",
                                "id" => @parent1.label.id,
                                "text" => @parent1.label.text },
                 },
                 view)
  end

  def test_loading_batching
    log_queries do
      serialize(Views::Parent.load)
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

    pv = Views::Parent.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal("p", p.name)

    assert(p.label.present?)
    assert_equal("l", p.label.text)
  end

  def test_create_belongs_to_nil
    view = { '_type' => 'Parent', 'name' => 'p', 'label' => nil }
    pv = Views::Parent.deserialize_from_view(view)
    assert_nil(pv.model.label)
  end

  def test_belongs_to_create
    @parent1.update(label: nil)

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['label'] = { '_type' => 'Label', 'text' => 'cheese' }
    end

    assert_equal('cheese', @parent1.label.text)
  end

  def test_belongs_to_replace
    old_label = @parent1.label

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['label'] = { '_type' => 'Label', 'text' => 'cheese' }
    end

    assert_equal('cheese', @parent1.label.text)
    assert(Label.where(id: old_label).blank?)
  end

  def test_belongs_to_move_and_replace
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    set_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
      p1['label'] = nil
      p2['label'] = update_hash_for(Views::Label, old_p1_label)
    end

    assert(@parent1.label.blank?, 'l1 label reference removed')
    assert_equal(old_p1_label, @parent2.label, 'p2 has label from p1')
    assert(Label.where(id: old_p2_label).blank?, 'p2 old label deleted')
  end

  def test_belongs_to_move_and_replace_from_outside_tree
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    ex = assert_raises(ViewModel::DeserializationError) do
      set_by_view!(Views::Parent, @parent2) do |p2, refs|
        p2['label'] = update_hash_for(Views::Label, old_p1_label)
      end
    end

    # For now, we don't allow moving unless the pointer is from child to parent,
    # as it's more involved to safely resolve the old parent in the other
    # direction.
    assert_match(/Cannot resolve previous parents for the following referenced viewmodels/, ex.message)
  end

  def test_belongs_to_swap
    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
      p1['label'] = update_hash_for(Views::Label, old_p2_label)
      p2['label'] = update_hash_for(Views::Label, old_p1_label)
    end

    assert_equal(old_p2_label, @parent1.label, 'p1 has label from p2')
    assert_equal(old_p1_label, @parent2.label, 'p2 has label from p1')
  end

  def test_belongs_to_build_new_association
    skip("unimplemented")

    old_label = @parent1.label

    Views::Parent.new(@parent1).deserialize_associated(:label, { "text" => "l2" })

    @parent1.reload

    assert(Label.where(id: old_label.id).blank?)
    assert_equal("l2", @parent1.label.text)
  end

  def test_belongs_to_update_existing_association
    skip("unimplemented")

    label = @parent1.label
    lv = Views::Label.new(label).to_hash
    lv["text"] = "renamed"

    Views::Parent.new(@parent1).deserialize_associated(:label, lv)

    @parent1.reload

    assert_equal(label, @parent1.label)
    assert_equal("renamed", @parent1.label.text)
  end

  def test_belongs_to_move_existing_association
    skip("unimplemented")

    old_p1_label = @parent1.label
    old_p2_label = @parent2.label

    Views::Parent.new(@parent2).deserialize_associated("label", { "id" => old_p1_label.id })

    @parent1.reload
    @parent2.reload

    assert(@parent1.label.blank?)
    assert(Label.where(id: old_p2_label.id).blank?)

    assert_equal(old_p1_label, @parent2.label)
    assert_equal("p1l", @parent2.label.text)
  end

  def test_implicit_release_invalid_belongs_to
    taken_label_ref = update_hash_for(Views::Label, @parent1.label)
    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(
        [{ '_type' => 'Parent',
           'name'  => 'newp',
           'label' => taken_label_ref }])
    end

    assert_match(/Cannot resolve previous parents/, ex.message,
                 'belongs_to does not infer previous parents')
  end

  class GCTests < ActiveSupport::TestCase
    include ARVMTestUtilities
    include WithOwner
    include WithLabel

    # test belongs_to garbage collection - dependent: delete_all
    def test_gc_dependent_delete_all
      owner = Owner.create(deleted: Label.new(text: 'one'))
      old_label = owner.deleted

      alter_by_view!(Views::Owner, owner) do |ov, refs|
        ov['deleted'] = { '_type' => 'Label', 'text' => 'two' }
      end

      assert_equal('two', owner.deleted.text)
      refute_equal(old_label, owner.deleted)
      assert(Label.where(id: old_label.id).blank?)
    end

    def test_no_gc_dependent_ignore
      owner = Owner.create(ignored: Label.new(text: "one"))
      old_label = owner.ignored

      alter_by_view!(Views::Owner, owner) do |ov, refs|
        ov['ignored'] = { '_type' => 'Label', 'text' => 'two' }
      end
      assert_equal('two', owner.ignored.text)
      refute_equal(old_label, owner.ignored)
      assert_equal(1, Label.where(id: old_label.id).count)
    end
  end

end
