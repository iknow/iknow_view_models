require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"
require 'minitest/unit'

require "view_model/active_record"

class ViewModel::AccessControlTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  class ComposedTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      super

      build_viewmodel(:List) do
        define_schema do |t|
          t.string  :car
          t.integer :cdr_id
        end

        define_model do
          belongs_to :cdr, class_name: :List, dependent: :destroy
        end

        define_viewmodel do
          attribute   :car
          association :cdr

          def self.new_serialize_context(**args)
            super(access_control: TestAccessControl.new, **args)
          end

          def self.new_deserialize_context(**args)
            super(access_control: TestAccessControl.new, **args)
          end
        end
      end
    end

    def setup
      ComposedTest.const_set(:TestAccessControl, Class.new(ViewModel::AccessControl::Composed))
      enable_logging!
    end

    def teardown
      ComposedTest.send(:remove_const, :TestAccessControl)
    end

    def test_visible_if
      TestAccessControl.visible_if!("car is visible1") do
        view.car == "visible1"
      end

      TestAccessControl.visible_if!("car is visible2") do
        view.car == "visible2"
      end

      assert_serializes(ListView, List.create!(car: "visible1"))
      assert_serializes(ListView, List.create!(car: "visible2"))
      ex = refute_serializes(ListView, List.create!(car: "bad"), /none of the possible/)
      assert_equal(2, ex.reasons.count)
    end

    def test_visible_unless
      TestAccessControl.visible_if!("always") { true }

      TestAccessControl.visible_unless!("car is invisible") do
        view.car == "invisible"
      end

      assert_serializes(ListView, List.create!(car: "ok"))
      refute_serializes(ListView, List.create!(car: "invisible"), /not permitted.*car is invisible/)
    end

    def test_editable_if
      TestAccessControl.visible_if!("always") { true }

      TestAccessControl.editable_if!("car is editable1") do
        view.car == "editable1"
      end

      TestAccessControl.editable_if!("car is editable2") do
        view.car == "editable2"
      end

      assert_deserializes(ListView, List.create!(car: "editable1")) { |v, _| v["car"] = "unchecked" }
      assert_deserializes(ListView, List.create!(car: "editable2")) { |v, _| v["car"] = "unchecked" }
      assert_deserializes(ListView, List.create!(car: "forbidden")) { |v, _| v["car"] = "forbidden" } # no change so permitted
      refute_deserializes(ListView, List.create!(car: "forbidden"), /none of the possible/) { |v, _| v["car"] = "unchecked" }
    end

    def test_editable_unless
      TestAccessControl.visible_if!("always") { true }
      TestAccessControl.editable_if!("always") { true }

      TestAccessControl.editable_unless!("car is uneditable") do
        view.car == "uneditable"
      end

      assert_deserializes(ListView, List.create!(car: "ok")) { |v, _| v["car"] = "unchecked" }
      assert_deserializes(ListView, List.create!(car: "uneditable")) { |v, _| v["car"] = "uneditable" } # no change so permitted
      refute_deserializes(ListView, List.create!(car: "uneditable"), /car is uneditable/) { |v, _| v["car"] = "unchecked" }
    end

    def test_edit_valid_if
      TestAccessControl.visible_if!("always") { true }

      TestAccessControl.edit_valid_if!("car is validedit") do
        view.car == "validedit"
      end

      assert_deserializes(ListView, List.create!(car: "unchecked"))  { |v, _| v["car"] = "validedit" }
      assert_deserializes(ListView, List.create!(car: "unmodified")) { |v, _| v["car"] = "unmodified" } # no change so permitted
      refute_deserializes(ListView, List.create!(car: "unchecked"), /none of the possible/) { |v, _| v["car"] = "bad" }
    end

    def test_edit_valid_unless
      TestAccessControl.visible_if!("always") { true }
      TestAccessControl.edit_valid_if!("always") { true }
      TestAccessControl.edit_valid_unless!("car is invalidedit") do
        view.car == "invalidedit"
      end

      assert_deserializes(ListView, List.create!(car: "unchecked"))   { |v, _| v["car"] = "ok" }
      assert_deserializes(ListView, List.create!(car: "invalidedit")) { |v, _| v["car"] = "invalidedit" }
      refute_deserializes(ListView, List.create!(car: "unchecked"), /car is invalidedit/) { |v, _| v["car"] = "invalidedit" }
    end

    def test_editable_and_edit_valid
      TestAccessControl.visible_if!("always") { true }

      TestAccessControl.editable_if!("original car permits") do
        view.car == "permitoriginal"
      end

      TestAccessControl.edit_valid_if!("resulting car permits") do
        view.car == "permitresult"
      end

      # at least one valid
      assert_deserializes(ListView, List.create!(car: "permitoriginal")) { |v, _| v["car"] = "permitresult" }
      assert_deserializes(ListView, List.create!(car: "badoriginal"))    { |v, _| v["car"] = "permitresult" }
      assert_deserializes(ListView, List.create!(car: "permitoriginal")) { |v, _| v["car"] = "badresult" }

      # no valid
      ex = refute_deserializes(ListView, List.create!(car: "badoriginal"), /none of the possible/) { |v, _| v["car"] = "badresult" }

      assert_equal(2, ex.reasons.count)
    end

    def test_inheritance
      child_access_control = Class.new(ViewModel::AccessControl::Composed)
      child_access_control.include_from(TestAccessControl)

      TestAccessControl.visible_if!("car is ancestor") { view.car == "ancestor" }
      child_access_control.visible_if!("car is descendent") { view.car == "descendent" }

      s_ctx = ListView.new_serialize_context(access_control: child_access_control.new)

      assert_serializes(ListView, List.create!(car: "ancestor"), serialize_context: s_ctx)
      assert_serializes(ListView, List.create!(car: "descendent"), serialize_context: s_ctx)
      ex = refute_serializes(ListView, List.create!(car: "foreigner"), serialize_context: s_ctx)
      assert_equal(2, ex.reasons.count)
    end

    def test_add_to_env
      TestAccessControl.class_eval do
        attr_reader :env_data
        def initialize(env_data = "data")
          @env_data = env_data
        end
        add_to_env :env_data
      end

      TestAccessControl.visible_if!("car matches env_data") { view.car == env_data }

      assert_serializes(ListView, List.create!(car: "data"))
      refute_serializes(ListView, List.create!(car: "failure"))

      s_ctx = ListView.new_serialize_context(access_control: TestAccessControl.new("data2"))
      assert_serializes(ListView, List.create!(car: "data2"), serialize_context: s_ctx)
    end
  end

  class TreeTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      super

      build_viewmodel(:Tree1) do
        define_schema do |t|
          t.string  :val
          t.integer :tree2_id
        end

        define_model do
          belongs_to :tree2, class_name: :Tree2, dependent: :destroy
        end

        define_viewmodel do
          attribute   :val
          association :tree2

          def self.new_serialize_context(**args)
            super(access_control: TestAccessControl.new, **args)
          end

          def self.new_deserialize_context(**args)
            super(access_control: TestAccessControl.new, **args)
          end
        end
      end

      build_viewmodel(:Tree2) do
        define_schema do |t|
          t.string  :val
          t.integer :tree1_id
        end

        define_model do
          belongs_to :tree1, class_name: :Tree1, dependent: :destroy
        end

        define_viewmodel do
          attribute   :val
          association :tree1
        end
      end
    end

    def setup
      TreeTest.const_set(:TestAccessControl, Class.new(ViewModel::AccessControl::Tree))
      enable_logging!
    end

    def teardown
      TreeTest.send(:remove_const, :TestAccessControl)
    end

    def make_tree(*vals)
      tree = vals.each_slice(2).reverse_each.inject(nil) do |rest, (t1, t2)|
        Tree1.new(val: t1, tree2: Tree2.new(val: t2, tree1: rest))
      end
      tree.save!
      tree
    end

    def test_visibility_from_root
      TestAccessControl.view "Tree1", root: true do
        visible_if!("true") { true }

        root_children_visible_if!("root children visible") do
          view.val == "visible_children"
        end
      end

      refute_serializes(Tree1View, make_tree("visible", "invisible"))
      assert_serializes(Tree1View, make_tree("visible_children", "invisible"))

      # nested root
      refute_serializes(Tree1View, make_tree("visible_children", "invisible", "visible", "invisible"))
      assert_serializes(Tree1View, make_tree("visible_children", "invisible", "visible_children", "visible"))
    end

    def test_visibility_veto_from_root
      TestAccessControl.view "Tree1", root: true do
        root_children_visible_unless!("root children invisible") do
          view.val == "invisible_children"
        end
      end

      TestAccessControl.always do
        visible_if!("true") { true }
      end

      assert_serializes(Tree1View, make_tree("visible", "visible"))
      refute_serializes(Tree1View, make_tree("invisible_children", "invisible"))

      # nested root
      assert_serializes(Tree1View, make_tree("visible", "visible", "visible", "visible"))
      refute_serializes(Tree1View, make_tree("visible", "visible", "invisible_children", "invisible"))
    end

    def test_editability_from_root
      TestAccessControl.always do
        visible_if!("always") { true }
      end

      TestAccessControl.view "Tree1", root: true do
        editable_if!("true") { true }

        root_children_editable_if!("root children editable") do
          view.val == "editable_children"
        end
      end


      refute_deserializes(Tree1View, make_tree("editable", "uneditable")) { |v, _|
        v["tree2"]["val"] = "change"
      }

      assert_deserializes(Tree1View, make_tree("editable_children", "editable")) { |v, _|
        v["tree2"]["val"] = "change"
      }

      # nested root
      refute_deserializes(Tree1View, make_tree("editable_children", "uneditable", "editable", "uneditable")) { |v, _|
        v["tree2"]["tree1"]["tree2"]["val"] = "change"
      }

      assert_deserializes(Tree1View, make_tree("editable_children", "uneditable", "editable_children", "editable")) { |v, _|
        v["tree2"]["tree1"]["tree2"]["val"] = "change"
      }
    end

    def test_editability_veto_from_root
      TestAccessControl.always do
        visible_if!("always") { true }
        editable_if!("always") { true }
      end

      TestAccessControl.view "Tree1", root: true do
        root_children_editable_unless!("root children uneditable") do
          view.val == "uneditable_children"
        end
      end


      refute_deserializes(Tree1View, make_tree("uneditable_children", "uneditable")) { |v, _|
        v["tree2"]["val"] = "change"
      }

      assert_deserializes(Tree1View, make_tree("editable", "editable")) { |v, _|
        v["tree2"]["val"] = "change"
      }

      # nested root
      refute_deserializes(Tree1View, make_tree("editable", "editable", "uneditable_children", "uneditable")) { |v, _|
        v["tree2"]["tree1"]["tree2"]["val"] = "change"
      }

      assert_deserializes(Tree1View, make_tree("editable", "editable", "editable", "editable")) { |v, _|
        v["tree2"]["tree1"]["tree2"]["val"] = "change"
      }
    end

    def test_type_independence
      TestAccessControl.view "Tree1" do
        visible_if!("tree1 visible") do
          view.val == "tree1visible"
        end
      end

      TestAccessControl.view "Tree2" do
        visible_if!("tree2 visible") do
          view.val == "tree2visible"
        end
      end

      refute_serializes(Tree1View, make_tree("tree1invisible","tree2visible"))
      assert_serializes(Tree1View, make_tree("tree1visible", "tree2visible"))
      refute_serializes(Tree1View, make_tree("tree1visible", "tree2invisible"))
    end

    def test_visibility_always_composition
      TestAccessControl.view "Tree1" do
        visible_if!("tree1 visible") do
          view.val == "tree1visible"
        end
      end

      TestAccessControl.always do
        visible_if!("tree2 visible") do
          view.val == "alwaysvisible"
        end
      end

      refute_serializes(Tree1View, Tree1.create(val: "bad"))
      assert_serializes(Tree1View, Tree1.create(val: "tree1visible"))
      assert_serializes(Tree1View, Tree1.create(val: "alwaysvisible"))
    end

    def test_editability_always_composition
      TestAccessControl.view "Tree1" do
        editable_if!("editable1")   { view.val == "editable1" }
        edit_valid_if!("editvalid1") { view.val == "editvalid1" }
      end

      TestAccessControl.always do
        editable_if!("editable2")   { view.val == "editable2" }
        edit_valid_if!("editvalid2") { view.val == "editvalid2" }

        visible_if!("always") { true }
      end


      refute_deserializes(Tree1View, Tree1.create!(val: "bad")) { |v, _| v["val"] = "alsobad" }

      assert_deserializes(Tree1View, Tree1.create!(val: "editable1")) { |v, _| v["val"] = "unchecked" }
      assert_deserializes(Tree1View, Tree1.create!(val: "editable2")) { |v, _| v["val"] = "unchecked" }

      assert_deserializes(Tree1View, Tree1.create!(val: "unchecked")) { |v, _| v["val"] = "editvalid1" }
      assert_deserializes(Tree1View, Tree1.create!(val: "unchecked")) { |v, _| v["val"] = "editvalid2" }
    end

    def test_ancestry
      TestAccessControl.view "Tree1" do
        visible_if!("parent tree1") { view.val == "parenttree1" }
      end

      TestAccessControl.always do
        visible_if!("parent always") { view.val == "parentalways" }
      end

      # Child must be set up after parent is fully defined
      child_access_control = Class.new(ViewModel::AccessControl::Tree)
      child_access_control.include_from(TestAccessControl)

      child_access_control.view "Tree1" do
        visible_if!("child tree1") { view.val == "childtree1" }
      end

      child_access_control.always do
        visible_if!("child always") { view.val == "childalways" }
      end

      s_ctx = Tree1View.new_serialize_context(access_control: child_access_control.new)

      refute_serializes(Tree1View, Tree1.create!(val: "bad"), serialize_context: s_ctx)

      assert_serializes(Tree1View, Tree1.create!(val: "parenttree1"), serialize_context: s_ctx)
      assert_serializes(Tree1View, Tree1.create!(val: "parentalways"), serialize_context: s_ctx)
      assert_serializes(Tree1View, Tree1.create!(val: "childtree1"), serialize_context: s_ctx)
      assert_serializes(Tree1View, Tree1.create!(val: "childalways"), serialize_context: s_ctx)
    end

    def test_add_to_env
      TestAccessControl.class_eval do
        attr_reader :env_data
        def initialize(env_data = "data")
          super()
          @env_data = env_data
        end
      end

      TestAccessControl.add_to_env :env_data

      TestAccessControl.view "Tree1" do
        visible_if!("val matches env_data") { view.val == env_data }
      end

      TestAccessControl.always do
        visible_if!("val starts with env_data") { view.val.start_with?(env_data) }
      end

      assert_serializes(Tree1View, Tree1.create!(val: "data"))
      assert_serializes(Tree1View, Tree1.create!(val: "data-plus"))
      refute_serializes(Tree1View, Tree1.create!(val: "bad-data"))

      s_ctx = Tree1View.new_serialize_context(access_control: TestAccessControl.new("other"))

      assert_serializes(Tree1View, Tree1.create!(val: "other"), serialize_context: s_ctx)
    end
  end

  # Test edit check integration: do the various access control methods get
  # called as expected, with expected parameters?
  class IntegrationTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      build_viewmodel(:List) do
        define_schema do |t|
          t.string  :car
          t.integer :cdr_id
        end

        define_model do
          belongs_to :cdr, class_name: :List, dependent: :destroy
        end

        define_viewmodel do
          attribute   :car
          association :cdr
        end
      end
    end

    # Extract edit check changes for a given view as an array.
    def edit_check(ctx, ref)
      changes = ctx.valid_edit_changes(ref)
      [changes.changed_attributes, changes.changed_associations, changes.deleted]
    end

    def test_changes_types
      l = List.create!
      lv, ctx = alter_by_view!(ListView, l) do |view, refs|
        view["car"] = "a"
        view["cdr"] = { "_type" => "List", "car" => "b" }
      end

      lv_changes = ctx.valid_edit_changes(lv.to_reference)

      assert_equal(["cdr_id", "car"], lv_changes.changed_attributes)
      assert_equal(["cdr"], lv_changes.changed_associations)
      assert_equal(false,   lv_changes.deleted)
    end

    def test_editable_change_attribute
      l = List.create!(car: "a")

      _lv, ctx = alter_by_view!(ListView, l) do |view, refs|
        view["car"] = nil
      end

      edits = edit_check(ctx, ViewModel::Reference.new(ListView, l.id))
      assert_equal([["car"], [], false], edits)
    end

    def test_editable_add_association
      l = List.create!(car: "a")

      _lv, ctx = alter_by_view!(ListView, l) do |view, refs|
        view["cdr"] = { "_type" => "List", "car" => "b" }
      end

      l_edits = edit_check(ctx, ViewModel::Reference.new(ListView, l.id))
      assert_equal([["cdr_id"], ["cdr"], false], l_edits)

      c_edits = edit_check(ctx, ViewModel::Reference.new(ListView, nil))
      assert_equal([["car"], [], false], c_edits)
    end

    def test_editable_change_association
      l = List.create!(car: "a", cdr: List.new(car: "b"))
      l2 = l.cdr

      _lv, ctx = alter_by_view!(ListView, l) do |view, refs|
        view["cdr"] = { "_type" => "List", "car" => "c" }
      end

      l_edits = edit_check(ctx, ViewModel::Reference.new(ListView, l.id))
      assert_equal([["cdr_id"], ["cdr"], false], l_edits)

      l2_edits = edit_check(ctx, ViewModel::Reference.new(ListView, l2.id))
      assert_equal([[], [], true], l2_edits)

      c_edits = edit_check(ctx, ViewModel::Reference.new(ListView, nil))
      assert_equal([["car"], [], false], c_edits)
    end

    def test_editable_delete_association
      l = List.create!(car: "a", cdr: List.new(car: "b"))
      l2 = l.cdr

      _lv, ctx = alter_by_view!(ListView, l) do |view, refs|
        view["cdr"] = nil
      end

      l_edits = edit_check(ctx, ViewModel::Reference.new(ListView, l.id))
      assert_equal([["cdr_id"], ["cdr"], false], l_edits)

      l2_edits = edit_check(ctx, ViewModel::Reference.new(ListView, l2.id))
      assert_equal([[], [], true], l2_edits)
    end
  end
end
