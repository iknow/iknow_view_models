require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

class ActiveRecordViewModel::HasOneTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def self.build_target(arvm_test_case)
    arvm_test_case.build_viewmodel(:Target) do
      define_schema do |t|
        t.string :text
        t.references :parent, foreign_key: true
      end

      define_model do
        belongs_to :parent, inverse_of: :target
      end

      define_viewmodel do
        attributes :text
        include TrivialAccessControl
      end
    end
  end


  def self.build_parent(arvm_test_case)
    arvm_test_case.build_viewmodel(:Parent) do
      define_schema do |t|
        t.string :name
      end

      define_model do
        has_one    :target, dependent: :destroy, inverse_of: :parent
      end

      define_viewmodel do
        attributes   :name
        associations :target
        include TrivialAccessControl
      end
    end
  end

  def before_all
    super

    self.class.build_parent(self)
    self.class.build_target(self)
  end

  def setup
    super

    # TODO make a `has_list?` that allows a parent to set all children as an array
    @parent1 = Parent.new(name: "p1",
                          target: Target.new(text: "p1t"))
    @parent1.save!

    @parent2 = Parent.new(name: "p2",
                          target: Target.new(text: "p2t"))

    @parent2.save!

    enable_logging!
  end

  def test_loading_batching
    log_queries do
      serialize(Views::Parent.load)
    end
    assert_equal(['Parent Load', 'Target Load'],
                 logged_load_queries)
  end

  def test_create_from_view
    view = {
      "_type"    => "Parent",
      "name"     => "p",
      "target"   => { "_type" => "Target", "text" => "t" },
    }

    pv = Views::Parent.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal("p", p.name)


    assert(p.target.present?)
    assert_equal("t", p.target.text)
  end

  def test_serialize_view
    view, _refs = serialize_with_references(Views::Parent.new(@parent1))
    assert_equal({ "_type" => "Parent",
                   "id" => @parent1.id,
                   "name" => @parent1.name,
                   "target" => { "_type" => "Target",
                                 "id" => @parent1.target.id,
                                 "text" => @parent1.target.text }},
                view)
  end

  def test_swap_has_one
    @parent1.update(target: t1 = Target.new)
    @parent2.update(target: t2 = Target.new)

    deserialize_context = Views::ApplicationBase::DeserializeContext.new

    Views::Parent.deserialize_from_view(
      [update_hash_for(Views::Parent, @parent1) { |p| p['target'] = update_hash_for(Views::Target, t2) },
       update_hash_for(Views::Parent, @parent2) { |p| p['target'] = update_hash_for(Views::Target, t1) }],
      deserialize_context: deserialize_context)

    assert_equal(Set.new([[Views::Parent, @parent1.id],
                          [Views::Parent, @parent2.id],
                          [Views::Target, t1.id],
                          [Views::Target, t2.id]]),
                 deserialize_context.edit_checks.to_set)

    @parent1.reload
    @parent2.reload

    assert_equal(@parent1.target, t2)
    assert_equal(@parent2.target, t1)
  end

  def test_has_one_create_nil
    view = { '_type' => 'Parent', 'name' => 'p', 'target' => nil }
    pv = Views::Parent.deserialize_from_view(view)
    assert_nil(pv.model.target)
  end

  def test_has_one_create
    @parent1.update(target: nil)

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['target'] = { '_type' => 'Target', 'text' => 't' }
    end

    assert_equal('t', @parent1.target.text)
  end

  def test_has_one_update
    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['target']['text'] = "hello"
    end

    assert_equal('hello', @parent1.target.text)
  end

  def test_has_one_destroy
    old_target = @parent1.target
    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['target'] = nil
    end
    assert(Target.where(id: old_target.id).blank?)
  end

  def test_has_one_move_and_replace
    old_parent1_target = @parent1.target
    old_parent2_target = @parent2.target

    alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
      p2['target'] = p1['target']
      p1['target'] = nil
    end

    assert(@parent1.target.blank?)
    assert_equal(old_parent1_target, @parent2.target)
    assert(Target.where(id: old_parent2_target).blank?)
  end

  def test_has_one_move_and_replace_from_outside_tree
    old_parent1_target = @parent1.target
    old_parent2_target = @parent2.target

    alter_by_view!(Views::Parent, @parent2) do |p2, refs|
      p2['target'] = update_hash_for(Views::Target, old_parent1_target)
    end

    @parent1.reload

    assert(@parent1.target.blank?)
    assert_equal(old_parent1_target, @parent2.target)
    assert(Target.where(id: old_parent2_target).blank?)
  end

  def test_has_one_cannot_duplicate_from_outside_tree
    # p2 shouldn't be able to copy p1's target, because attempting to take t1
    # from outside the tree will create an new update operation for it, which
    # will conflict with the one already present in p1.
    ex = assert_raises(ViewModel::DeserializationError) do
      alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
        p2['target'] = p1['target'].dup
      end
    end
    assert_match(/Not a valid type transition: explicit -> explicit/, ex.message)
  end

  def test_has_one_cannot_duplicate_implicitly_from_outside_tree
    # p2 shouldn't be able to copy p1's target even when p1 doesn't explicitly
    # specify it, because attempting to take t1 from outside the tree will
    # create an new update operation for its old parent (p1), which will
    # conflict with the p1 update.
    ex = assert_raises(ViewModel::DeserializationError) do
      alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
        p2['target'] = p1['target']
        p1.delete('target')
      end
    end
    assert_match(/Not a valid type transition: explicit -> implicit/, ex.message)
  end

  def test_has_one_cannot_take_twice_from_outside_tree
    t3 = Parent.create(target: Target.new(text: 'hi')).target

    ex = assert_raises(ViewModel::DeserializationError) do
      alter_by_view!(Views::Parent, [@parent1, @parent2]) do |(p1, p2), refs|
        p1['target'] = update_hash_for(Views::Target, t3)
        p2['target'] = update_hash_for(Views::Target, t3)
      end
    end
    assert_match(/Not a valid type transition: explicit -> explicit/, ex.message)
  end

  def test_has_one_take_unparented_from_outside_tree
    t3 = Target.create(text: 'hi') # no parent

    alter_by_view!(Views::Parent, @parent1) do |p1, refs|
      p1['target'] = update_hash_for(Views::Target, t3)
    end
  end

  def test_bad_single_association
    view = {
      "_type" => "Parent",
      "target" => []
    }
    ex = assert_raises(ViewModel::DeserializationError) do
      Views::Parent.deserialize_from_view(view)
    end
    assert_match(/not a hash/, ex.message)
  end


  class RenameTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      super

      build_viewmodel(:Parent) do
        define_schema do |t|
          t.string :name
        end

        define_model do
          has_one    :target, dependent: :destroy, inverse_of: :parent
        end

        define_viewmodel do
          attributes   :name
          association :target, as: :something_else
          include TrivialAccessControl
        end
      end

      ActiveRecordViewModel::HasOneTest.build_target(self)
    end

    def setup
      super

      @parent = Parent.create(target: Target.new(text: 'target text'))

      enable_logging!
    end

    def test_renamed_roundtrip
      alter_by_view!(Views::Parent, @parent) do |view, refs|
        assert_equal({'id' => @parent.target.id,
                     '_type' => 'Target',
                     'text' => 'target text'},
                     view['something_else'])
        view['something_else']['text'] = 'target new text'
      end

      assert_equal('target new text',  @parent.target.text)
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


    def test_move
      model = Aye.create(bee: Bee.new(cee: Cee.new))

      # This test currently fails because we allow the new to Bee to resolve the
      # Cee directly from the database when its old parent Bee (in the previous
      # tree) has been put on the release pool and is about to delete it.
      alter_by_view!(Views::Aye, model) do |view, refs|
        view['bee'].delete("id")
      end
    end
  end

end
