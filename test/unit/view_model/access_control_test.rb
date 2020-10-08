# frozen_string_literal: true

require_relative '../../helpers/arvm_test_utilities.rb'
require_relative '../../helpers/arvm_test_models.rb'
require_relative '../../helpers/viewmodel_spec_helpers.rb'

require 'minitest/autorun'
require 'minitest/unit'

require 'rspec/expectations/minitest_integration'

require 'view_model/active_record'

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
      TestAccessControl.visible_if!('car is visible1') do
        view.car == 'visible1'
      end

      TestAccessControl.visible_if!('car is visible2') do
        view.car == 'visible2'
      end

      assert_serializes(ListView, List.create!(car: 'visible1'))
      assert_serializes(ListView, List.create!(car: 'visible2'))
      ex = refute_serializes(ListView, List.create!(car: 'bad'), /none of the possible/)
      assert_equal(2, ex.reasons.count)
    end

    def test_visible_unless
      TestAccessControl.visible_if!('always') { true }

      TestAccessControl.visible_unless!('car is invisible') do
        view.car == 'invisible'
      end

      assert_serializes(ListView, List.create!(car: 'ok'))
      refute_serializes(ListView, List.create!(car: 'invisible'), /not permitted.*car is invisible/)
    end

    def test_editable_if
      TestAccessControl.visible_if!('always') { true }

      TestAccessControl.editable_if!('car is editable1') do
        view.car == 'editable1'
      end

      TestAccessControl.editable_if!('car is editable2') do
        view.car == 'editable2'
      end

      assert_deserializes(ListView, List.create!(car: 'editable1')) { |v, _| v['car'] = 'unchecked' }
      assert_deserializes(ListView, List.create!(car: 'editable2')) { |v, _| v['car'] = 'unchecked' }
      assert_deserializes(ListView, List.create!(car: 'forbidden')) { |v, _| v['car'] = 'forbidden' } # no change so permitted
      refute_deserializes(ListView, List.create!(car: 'forbidden'), /none of the possible/) { |v, _| v['car'] = 'unchecked' }
    end

    def test_editable_unless
      TestAccessControl.visible_if!('always') { true }
      TestAccessControl.editable_if!('always') { true }

      TestAccessControl.editable_unless!('car is uneditable') do
        view.car == 'uneditable'
      end

      assert_deserializes(ListView, List.create!(car: 'ok')) { |v, _| v['car'] = 'unchecked' }
      assert_deserializes(ListView, List.create!(car: 'uneditable')) { |v, _| v['car'] = 'uneditable' } # no change so permitted
      refute_deserializes(ListView, List.create!(car: 'uneditable'), /car is uneditable/) { |v, _| v['car'] = 'unchecked' }
    end

    def test_edit_valid_if
      TestAccessControl.visible_if!('always') { true }

      TestAccessControl.edit_valid_if!('car is validedit') do
        view.car == 'validedit'
      end

      assert_deserializes(ListView, List.create!(car: 'unchecked'))  { |v, _| v['car'] = 'validedit' }
      assert_deserializes(ListView, List.create!(car: 'unmodified')) { |v, _| v['car'] = 'unmodified' } # no change so permitted
      refute_deserializes(ListView, List.create!(car: 'unchecked'), /none of the possible/) { |v, _| v['car'] = 'bad' }
    end

    def test_edit_valid_unless
      TestAccessControl.visible_if!('always') { true }
      TestAccessControl.edit_valid_if!('always') { true }
      TestAccessControl.edit_valid_unless!('car is invalidedit') do
        view.car == 'invalidedit'
      end

      assert_deserializes(ListView, List.create!(car: 'unchecked'))   { |v, _| v['car'] = 'ok' }
      assert_deserializes(ListView, List.create!(car: 'invalidedit')) { |v, _| v['car'] = 'invalidedit' }
      refute_deserializes(ListView, List.create!(car: 'unchecked'), /car is invalidedit/) { |v, _| v['car'] = 'invalidedit' }
    end

    def test_editable_and_edit_valid
      TestAccessControl.visible_if!('always') { true }

      TestAccessControl.editable_if!('original car permits') do
        view.car == 'permitoriginal'
      end

      TestAccessControl.edit_valid_if!('resulting car permits') do
        view.car == 'permitresult'
      end

      # at least one valid
      assert_deserializes(ListView, List.create!(car: 'permitoriginal')) { |v, _| v['car'] = 'permitresult' }
      assert_deserializes(ListView, List.create!(car: 'badoriginal'))    { |v, _| v['car'] = 'permitresult' }
      assert_deserializes(ListView, List.create!(car: 'permitoriginal')) { |v, _| v['car'] = 'badresult' }

      # no valid
      ex = refute_deserializes(ListView, List.create!(car: 'badoriginal'), /none of the possible/) { |v, _| v['car'] = 'badresult' }

      assert_equal(2, ex.reasons.count)
    end

    def test_inheritance
      child_access_control = Class.new(ViewModel::AccessControl::Composed)
      child_access_control.include_from(TestAccessControl)

      TestAccessControl.visible_if!('car is ancestor') { view.car == 'ancestor' }
      child_access_control.visible_if!('car is descendent') { view.car == 'descendent' }

      s_ctx = ListView.new_serialize_context(access_control: child_access_control.new)

      assert_serializes(ListView, List.create!(car: 'ancestor'), serialize_context: s_ctx)
      assert_serializes(ListView, List.create!(car: 'descendent'), serialize_context: s_ctx)
      ex = refute_serializes(ListView, List.create!(car: 'foreigner'), serialize_context: s_ctx)
      assert_equal(2, ex.reasons.count)
    end
  end

  class TreeTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      super

      # Tree1 is a root, which owns Tree2.
      build_viewmodel(:Tree1) do
        define_schema do |t|
          t.string  :val
          t.integer :tree2_id
        end

        define_model do
          belongs_to :tree2, class_name: :Tree2, dependent: :destroy
        end

        define_viewmodel do
          root!
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

    def dig_tree(root, refs, attr, *rest)
      raise "Root missing attribute '#{attr}'" unless root.has_key?(attr)

      child = root[attr]

      if (child_ref = child['_ref'])
        child = refs[child_ref]
      end

      if rest.empty?
        child
      else
        dig_tree(child, refs, *rest)
      end
    end

    def test_visibility_from_root
      TestAccessControl.view 'Tree1' do
        visible_if!('true') { true }

        root_children_visible_if!('root children visible') do
          view.val == 'rule:visible_children'
        end
      end

      refute_serializes(Tree1View, make_tree('arbitrary parent',      'invisible child'))
      assert_serializes(Tree1View, make_tree('rule:visible_children', 'visible child'))

      # nested root
      refute_serializes(Tree1View, make_tree('rule:visible_children', 'visible child', 'arbitrary parent',      'invisible child'))
      assert_serializes(Tree1View, make_tree('rule:visible_children', 'visible child', 'rule:visible_children', 'visible child'))
    end

    def test_visibility_veto_from_root
      TestAccessControl.view 'Tree1' do
        root_children_visible_unless!('root children invisible') do
          view.val == 'rule:invisible_children'
        end
      end

      TestAccessControl.always do
        visible_if!('true') { true }
      end

      assert_serializes(Tree1View, make_tree('arbitrary parent',        'visible child'))
      refute_serializes(Tree1View, make_tree('rule:invisible_children', 'invisible child'))

      # nested root
      assert_serializes(Tree1View, make_tree('arbitrary parent', 'visible child', 'arbitrary nested parent', 'visible child'))
      refute_serializes(Tree1View, make_tree('arbitrary parent', 'visible child', 'rule:invisible_children', 'invisible child'))
    end

    def test_editability_from_root
      TestAccessControl.always do
        visible_if!('always') { true }
      end

      TestAccessControl.view 'Tree1' do
        editable_if!('true') { true }

        root_children_editable_if!('root children editable') do
          view.val == 'rule:editable_children'
        end
      end

      refute_deserializes(Tree1View, make_tree('arbitrary parent', 'uneditable child')) { |v, r|
        dig_tree(v, r, 'tree2')['val'] = 'change'
      }

      assert_deserializes(Tree1View, make_tree('rule:editable_children', 'editable child')) { |v, r|
        dig_tree(v, r, 'tree2')['val'] = 'change'
      }

      # nested root
      refute_deserializes(Tree1View, make_tree('rule:editable_children', 'editable child', 'arbitrary parent', 'uneditable child')) { |v, r|
        dig_tree(v, r, 'tree2', 'tree1', 'tree2')['val'] = 'change'
      }

      assert_deserializes(Tree1View, make_tree('arbitrary parent', 'uneditable child', 'rule:editable_children', 'editable child')) { |v, r|
        dig_tree(v, r, 'tree2', 'tree1', 'tree2')['val'] = 'change'
      }
    end

    def test_editability_veto_from_root
      TestAccessControl.always do
        visible_if!('always') { true }
        editable_if!('always') { true }
      end

      TestAccessControl.view 'Tree1' do
        root_children_editable_unless!('root children uneditable') do
          view.val == 'rule:uneditable_children'
        end
      end

      refute_deserializes(Tree1View, make_tree('rule:uneditable_children', 'uneditable child')) { |v, r|
        dig_tree(v, r, 'tree2')['val'] = 'change'
      }

      assert_deserializes(Tree1View, make_tree('arbitrary parent', 'editable child')) { |v, r|
        dig_tree(v, r, 'tree2')['val'] = 'change'
      }

      # nested root
      refute_deserializes(Tree1View, make_tree('arbitrary parent', 'editable child', 'rule:uneditable_children', 'uneditable child')) { |v, r|
        dig_tree(v, r, 'tree2', 'tree1', 'tree2')['val'] = 'change'
      }

      assert_deserializes(Tree1View, make_tree('rule:uneditable_children', 'uneditable child', 'arbitrary parent', 'editable child')) { |v, r|
        dig_tree(v, r, 'tree2', 'tree1', 'tree2')['val'] = 'change'
      }
    end

    def test_type_independence
      TestAccessControl.view 'Tree1' do
        visible_if!('tree1 visible') do
          view.val == 'tree1visible'
        end
      end

      TestAccessControl.view 'Tree2' do
        visible_if!('tree2 visible') do
          view.val == 'tree2visible'
        end
      end

      refute_serializes(Tree1View, make_tree('tree1invisible', 'tree2visible'))
      assert_serializes(Tree1View, make_tree('tree1visible', 'tree2visible'))
      refute_serializes(Tree1View, make_tree('tree1visible', 'tree2invisible'))
    end

    def test_visibility_always_composition
      TestAccessControl.view 'Tree1' do
        visible_if!('tree1 visible') do
          view.val == 'tree1visible'
        end
      end

      TestAccessControl.always do
        visible_if!('tree2 visible') do
          view.val == 'alwaysvisible'
        end
      end

      refute_serializes(Tree1View, Tree1.create(val: 'bad'))
      assert_serializes(Tree1View, Tree1.create(val: 'tree1visible'))
      assert_serializes(Tree1View, Tree1.create(val: 'alwaysvisible'))
    end

    def test_editability_always_composition
      TestAccessControl.view 'Tree1' do
        editable_if!('editable1')    { view.val == 'editable1' }
        edit_valid_if!('editvalid1') { view.val == 'editvalid1' }
      end

      TestAccessControl.always do
        editable_if!('editable2')    { view.val == 'editable2' }
        edit_valid_if!('editvalid2') { view.val == 'editvalid2' }

        visible_if!('always') { true }
      end

      refute_deserializes(Tree1View, Tree1.create!(val: 'bad')) { |v, _| v['val'] = 'alsobad' }

      assert_deserializes(Tree1View, Tree1.create!(val: 'editable1')) { |v, _| v['val'] = 'unchecked' }
      assert_deserializes(Tree1View, Tree1.create!(val: 'editable2')) { |v, _| v['val'] = 'unchecked' }

      assert_deserializes(Tree1View, Tree1.create!(val: 'unchecked')) { |v, _| v['val'] = 'editvalid1' }
      assert_deserializes(Tree1View, Tree1.create!(val: 'unchecked')) { |v, _| v['val'] = 'editvalid2' }
    end

    def test_ancestry
      TestAccessControl.view 'Tree1' do
        visible_if!('parent tree1') { view.val == 'parenttree1' }
      end

      TestAccessControl.always do
        visible_if!('parent always') { view.val == 'parentalways' }
      end

      # Child must be set up after parent is fully defined
      child_access_control = Class.new(ViewModel::AccessControl::Tree)
      child_access_control.include_from(TestAccessControl)

      child_access_control.view 'Tree1' do
        visible_if!('child tree1') { view.val == 'childtree1' }
      end

      child_access_control.always do
        visible_if!('child always') { view.val == 'childalways' }
      end

      s_ctx = Tree1View.new_serialize_context(access_control: child_access_control.new)

      refute_serializes(Tree1View, Tree1.create!(val: 'bad'), serialize_context: s_ctx)

      assert_serializes(Tree1View, Tree1.create!(val: 'parenttree1'), serialize_context: s_ctx)
      assert_serializes(Tree1View, Tree1.create!(val: 'parentalways'), serialize_context: s_ctx)
      assert_serializes(Tree1View, Tree1.create!(val: 'childtree1'), serialize_context: s_ctx)
      assert_serializes(Tree1View, Tree1.create!(val: 'childalways'), serialize_context: s_ctx)
    end
  end

  # Integration-test access control, callbacks and viewmodel change tracking: do
  # the edit checks get called as expected with the correct changes?
  class ChangeTrackingTest < ActiveSupport::TestCase
    include ARVMTestUtilities
    include ViewModelSpecHelpers::List
    extend Minitest::Spec::DSL

    def assert_changes_match(changes, n: false, d: false, nstc: false, refc: false, att: [], ass: [])
      assert_equal(
        changes,
        ViewModel::Changes.new(
          new: n,
          deleted: d,
          changed_nested_children: nstc,
          changed_referenced_children: refc,
          changed_attributes: att,
          changed_associations: ass))
    end

    describe 'with parent and points-to child test models' do
      include ViewModelSpecHelpers::ParentAndBelongsToChild

      def new_model
        model_class.new(name: 'a')
      end

      def new_model_with_child
        model_class.new(name: 'a', child: child_model_class.new(name: 'b'))
      end

      it 'records a created model' do
        view = {
          '_type' => view_name,
          'name'  => 'a',
        }

        ctx = viewmodel_class.new_deserialize_context
        vm = viewmodel_class.deserialize_from_view(view, deserialize_context: ctx)

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, n: true, att: ['name'])
      end

      it 'records a destroyed model' do
        vm = create_viewmodel!

        ctx = viewmodel_class.new_deserialize_context
        vm.destroy!(deserialize_context: ctx)

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, d: true)
      end

      it 'records a change to an attribute' do
        vm, ctx = alter_by_view!(viewmodel_class, create_model!) do |view, _refs|
          view['name'] = nil
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, att: ['name'])
      end

      it 'records a new child' do
        vm, ctx = alter_by_view!(viewmodel_class, create_model!) do |view, _refs|
          view['child'] = { '_type' => child_view_name, 'name' => 'b' }
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, nstc: true, ass: ['child'])

        c_changes = ctx.valid_edit_changes(vm.child.to_reference)
        assert_changes_match(c_changes, n: true, att: ['name'])
      end

      it 'records a replaced child' do
        m = new_model_with_child.tap(&:save!)
        old_child = m.child

        vm, ctx = alter_by_view!(viewmodel_class, m) do |view, _refs|
          view['child'] = { '_type' => child_view_name, 'name' => 'c' }
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, nstc: true, ass: ['child'])

        c_changes = ctx.valid_edit_changes(vm.child.to_reference)
        assert_changes_match(c_changes, n: true, att: ['name'])

        oc_changes = ctx.valid_edit_changes(
          ViewModel::Reference.new(child_viewmodel_class, old_child.id))
        assert_changes_match(oc_changes, d: true)
      end

      it 'records an edited child' do
        m = new_model_with_child.tap(&:save!)

        vm, ctx = alter_by_view!(viewmodel_class, m) do |view, _refs|
          view['child']['name'] = 'c'
        end

        # The parent node itself wasn't changed, so must not have been
        # valid_edit checked
        refute(ctx.was_edited?(vm.to_reference))
        assert_changes_match(vm.previous_changes, nstc: true)

        c_changes = ctx.valid_edit_changes(vm.child.to_reference)
        assert_changes_match(c_changes, att: ['name'])
      end

      it 'records a deleted child' do
        m = new_model_with_child.tap(&:save!)
        old_child = m.child

        vm, ctx = alter_by_view!(viewmodel_class, m) do |view, _refs|
          view['child'] = nil
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, nstc: true, ass: ['child'])

        oc_changes = ctx.valid_edit_changes(
          ViewModel::Reference.new(child_viewmodel_class, old_child.id))
        assert_changes_match(oc_changes, d: true)
      end
    end

    describe 'with parent and pointed-to child test models' do
      include ViewModelSpecHelpers::ParentAndOrderedChildren

      def new_model
        model_class.new(
          name: 'a',
          children: [child_model_class.new(name: 'x', position: 1),
                     child_model_class.new(name: 'y', position: 2)])
      end

      it 'records new children' do
        vm, ctx = alter_by_view!(viewmodel_class, create_model!) do |view, _refs|
          view['children'].concat(
            [
              { '_type' => child_view_name, 'name' => 'b' },
              { '_type' => child_view_name, 'name' => 'c' },
            ])
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, nstc: true, ass: ['children'])

        new_children, existing_children = vm.children.partition do |c|
          c.name < 'm'
        end

        new_children.each do |c|
          c_changes = ctx.valid_edit_changes(c.to_reference)
          assert_changes_match(c_changes, n: true, att: ['name'])
        end

        existing_children.each do |c|
          refute(ctx.was_edited?(c.to_reference))
        end
      end

      it 'records replaced children' do
        m = create_model!
        replaced_child = m.children.last

        vm, ctx = alter_by_view!(viewmodel_class, m) do |view, _refs|
          view['children'].pop
          view['children'] << { '_type' => child_view_name, 'name' => 'b' }
        end

        refute(vm.children.include?(replaced_child))

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, nstc: true, ass: ['children'])

        new_child = vm.children.detect { |c| c.name == 'b' }
        c_changes = ctx.valid_edit_changes(new_child.to_reference)
        assert_changes_match(c_changes, n: true, att: ['name'])

        oc_changes = ctx.valid_edit_changes(
          ViewModel::Reference.new(child_viewmodel_class, replaced_child.id))
        assert_changes_match(oc_changes, d: true)
      end

      it 'records reordered children' do
        vm, ctx = alter_by_view!(viewmodel_class, create_model!) do |view, _refs|
          view['children'].reverse!
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, ass: ['children'])

        vm.children.each do |c|
          refute(ctx.was_edited?(c.to_reference))
        end
      end
    end

    describe 'with parent and shared child test models' do
      include ViewModelSpecHelpers::ParentAndSharedBelongsToChild

      def new_model
        model_class.new(name: 'a', child: child_model_class.new(name: 'z'))
      end

      it 'records a change to child without a tree change' do
        vm, ctx = alter_by_view!(viewmodel_class, create_model!) do |view, refs|
          view['child'] = { '_ref' => 'cref' }
          refs.clear['cref'] = { '_type' => child_view_name, 'name' => 'b' }
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, ass: ['child'])

        c_changes = ctx.valid_edit_changes(vm.child.to_reference)
        assert_changes_match(c_changes, n: true, att: ['name'])
      end

      it 'records an edited child without a tree change' do
        vm, ctx = alter_by_view!(viewmodel_class, create_model!) do |_view, refs|
          refs.values.first.merge!('name' => 'b')
        end

        refute(ctx.was_edited?(vm.to_reference))
        assert_changes_match(vm.previous_changes)

        c_changes = ctx.valid_edit_changes(vm.child.to_reference)
        assert_changes_match(c_changes, att: ['name'])
      end

      it 'records a deleted child' do
        vm = create_viewmodel!
        old_child = vm.child

        vm, ctx = alter_by_view!(viewmodel_class, vm.model) do |view, refs|
          view['child'] = nil
          refs.clear
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, ass: ['child'])

        refute(ctx.was_edited?(old_child.to_reference))
      end
    end

    describe 'with parent and owned referenced child test models' do
      include ViewModelSpecHelpers::ParentAndReferencedHasOneChild

      def new_model
        model_class.new(name: 'a', child: child_model_class.new(name: 'z'))
      end

      it 'records a change to child with referenced tree change' do
        vm, ctx = alter_by_view!(viewmodel_class, create_model!) do |view, refs|
          view['child'] = { '_ref' => 'cref' }
          refs.clear['cref'] = { '_type' => child_view_name, 'name' => 'b' }
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, refc: true, ass: ['child'])

        c_changes = ctx.valid_edit_changes(vm.child.to_reference)
        assert_changes_match(c_changes, n: true, att: ['name'])
      end

      it 'records an edited child with referenced tree change' do
        vm, ctx = alter_by_view!(viewmodel_class, create_model!) do |_view, refs|
          refs.values.first.merge!('name' => 'b')
        end

        refute(ctx.was_edited?(vm.to_reference))
        assert_changes_match(vm.previous_changes, refc: true)

        c_changes = ctx.valid_edit_changes(vm.child.to_reference)
        assert_changes_match(c_changes, att: ['name'])
      end

      it 'records a deleted child' do
        vm = create_viewmodel!
        old_child = vm.child

        vm, ctx = alter_by_view!(viewmodel_class, vm.model) do |view, refs|
          view['child'] = nil
          refs.clear
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, refc: true, ass: ['child'])

        c_changes = ctx.valid_edit_changes(old_child.to_reference)
        assert_changes_match(c_changes, d: true)
      end
    end

    describe 'with has_many_through children test models' do
      include ViewModelSpecHelpers::ParentAndHasManyThroughChildren

      def new_model
        model_class.new(
          name: 'a',
          model_children: [
            join_model_class.new(position: 1, child: child_model_class.new(name: 'x')),
            join_model_class.new(position: 2, child: child_model_class.new(name: 'y')),
          ])
      end

      it 'records new children' do
        vm, ctx = alter_by_view!(viewmodel_class, create_model!) do |view, refs|
          view['children'].concat([{ '_ref' => 'new1' }, { '_ref' => 'new2' }])
          refs['new1'] = { '_type' => child_view_name, 'name' => 'b' }
          refs['new2'] = { '_type' => child_view_name, 'name' => 'c' }
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, ass: ['children'])

        new_children, existing_children = vm.children.partition do |c|
          c.name < 'm'
        end

        new_children.each do |c|
          c_changes = ctx.valid_edit_changes(c.to_reference)
          assert_changes_match(c_changes, n: true, att: ['name'])
        end

        existing_children.each do |c|
          refute(ctx.was_edited?(c.to_reference))
        end
      end

      it 'records replaced children' do
        vm = create_viewmodel!
        old_child = vm.children.first

        vm, ctx = alter_by_view!(viewmodel_class, vm.model) do |view, refs|
          refs.delete(view['children'].pop['_ref'])

          view['children'] << { '_ref' => 'new1' }
          refs['new1'] = { '_type' => child_view_name, 'name' => 'b' }
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, ass: ['children'])

        new_children, existing_children = vm.children.partition do |c|
          c.name < 'm'
        end

        new_children.each do |c|
          c_changes = ctx.valid_edit_changes(c.to_reference)
          assert_changes_match(c_changes, n: true, att: ['name'])
        end

        existing_children.each do |c|
          refute(ctx.was_edited?(c.to_reference))
        end

        refute(ctx.was_edited?(old_child.to_reference))
      end

      it 'records reordered children' do
        vm, ctx = alter_by_view!(viewmodel_class, create_model!) do |view, _refs|
          view['children'].reverse!
        end

        vm_changes = ctx.valid_edit_changes(vm.to_reference)
        assert_changes_match(vm_changes, ass: ['children'])

        vm.children.each do |c|
          refute(ctx.was_edited?(c.to_reference))
        end
      end
    end
  end
end
