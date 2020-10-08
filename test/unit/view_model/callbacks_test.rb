# frozen_string_literal: true

require_relative '../../helpers/arvm_test_utilities.rb'
require_relative '../../helpers/arvm_test_models.rb'
require_relative '../../helpers/callback_tracer.rb'
require_relative '../../helpers/viewmodel_spec_helpers.rb'

require 'minitest/autorun'

require 'view_model/active_record'

class ViewModel::CallbacksTest < ActiveSupport::TestCase
  include ARVMTestUtilities
  extend Minitest::Spec::DSL

  def vm_serialize_context(viewmodel_class, **args)
    viewmodel_class.new_serialize_context(callbacks: callbacks, **args)
  end

  def vm_deserialize_context(viewmodel_class, **args)
    viewmodel_class.new_deserialize_context(callbacks: callbacks, **args)
  end

  # Override TestHelpers to use the callback contexts
  def serialize(view, serialize_context: vm_serialize_context(view.class))
    super(view, serialize_context: serialize_context)
  end

  def serialize_with_references(view, serialize_context: vm_serialize_context(view.class))
    super(view, serialize_context: serialize_context)
  end

  # use `alter_by_view` to test deserialization: only override the deserialize_context
  def alter_by_view!(vm_class, model,
                     deserialize_context: vm_deserialize_context(vm_class),
                     **args,
                     &block)
    super(vm_class, model, deserialize_context: deserialize_context, **args, &block)
  end

  let(:callbacks) { [callback] }

  let(:vm) { create_viewmodel! }

  describe 'tracing each callback' do
    def visit(hook, view)
      CallbackTracer::Visit.new(hook, view)
    end

    let(:callback) { CallbackTracer.new }

    describe 'with parent and child test models' do
      include ViewModelSpecHelpers::ParentAndBelongsToChild

      def new_model
        model_class.new(name: 'a', child: child_model_class.new(name: 'b'))
      end

      it 'visits in correct order when serializing' do
        serialize(vm)
        value(callback.hook_trace).must_equal(
          [visit(ViewModel::Callbacks::Hook::BeforeVisit, vm),
           visit(ViewModel::Callbacks::Hook::BeforeVisit, vm.child),
           visit(ViewModel::Callbacks::Hook::AfterVisit,  vm.child),
           visit(ViewModel::Callbacks::Hook::AfterVisit,  vm),])
      end

      it 'visits in correct order when deserializing' do
        alter_by_view!(viewmodel_class, vm.model) {}
        value(callback.hook_trace).must_equal(
          [visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm.child),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm.child),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm.child),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm.child),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm.child),

           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),])
      end

      it 'calls edit hook when updating' do
        alter_by_view!(viewmodel_class, vm.model) do |view, _refs|
          view['name'] = 'q'
        end
        value(callback.hook_trace).must_equal(
          [visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm.child),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm.child),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm.child),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm.child),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm.child),

           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm),
           visit(ViewModel::Callbacks::Hook::OnChange,          vm),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),])
      end

      it 'calls edit hook when deleting' do
        vm_child = vm.child
        alter_by_view!(viewmodel_class, vm.model) do |view, _refs|
          view['child'] = nil
        end

        value(callback.hook_trace).must_equal(
          [visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm_child),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm_child),
           visit(ViewModel::Callbacks::Hook::OnChange,          vm_child),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm_child),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm_child),

           visit(ViewModel::Callbacks::Hook::OnChange,          vm),

           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),])
      end

      it 'calls hooks on old and new when replacing' do
        old_child = vm.child
        alter_by_view!(viewmodel_class, vm.model) do |view, _refs|
          view['child'] = { '_type' => 'Child', 'name' => 'q' }
        end

        value(callback.hook_trace).must_equal(
          [visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm.child),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm.child),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm.child),
           visit(ViewModel::Callbacks::Hook::OnChange,          vm.child),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm.child),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm.child),

           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       old_child),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, old_child),
           visit(ViewModel::Callbacks::Hook::OnChange,          old_child),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  old_child),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        old_child),

           visit(ViewModel::Callbacks::Hook::OnChange,          vm),

           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),])
      end

      it 'calls hooks on old and new when moving' do
        child = vm.child
        vm2 = viewmodel_class.new(model_class.create!(name: 'z'))
        alter_by_view!(viewmodel_class, [vm.model, vm2.model]) do |views, _refs|
          views[1]['child'] = views[0]['child']
          views[0]['child'] = nil
        end

        value(callback.hook_trace).must_equal(
          [visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm),
           visit(ViewModel::Callbacks::Hook::OnChange,          vm),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm2),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm2),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       child),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, child),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    child),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  child),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        child),

           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm2),
           visit(ViewModel::Callbacks::Hook::OnChange,          vm2),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm2),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm2),])
      end

      it 'calls hooks on delete' do
        ctx = vm_deserialize_context(viewmodel_class)
        vm.destroy!(deserialize_context: ctx)
        value(callback.hook_trace).must_equal(
          [visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),
           visit(ViewModel::Callbacks::Hook::OnChange,          vm),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),])
        ## At present, children aren't visited on delete.
        # visit(ViewModel::Callbacks::Hook::BeforeVisit,       old_child),
        # visit(ViewModel::Callbacks::Hook::BeforeDeserialize, old_child),
        # visit(ViewModel::Callbacks::Hook::OnChange,          old_child),
        # visit(ViewModel::Callbacks::Hook::AfterDeserialize,  old_child),
        # visit(ViewModel::Callbacks::Hook::AfterVisit,        old_child))
      end

      it 'calls hooks on replace associated' do
        old_child = vm.child
        ctx = vm_deserialize_context(viewmodel_class)
        new_child_hash = { '_type' => 'Child', 'name' => 'q' }
        vm.replace_associated(:child, new_child_hash, deserialize_context: ctx)
        vm.model.reload

        value(callback.hook_trace).must_equal(
          [
            visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
            visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),

            visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm.child),
            visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm.child),
            visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm.child),
            visit(ViewModel::Callbacks::Hook::OnChange,          vm.child),
            visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm.child),
            visit(ViewModel::Callbacks::Hook::AfterVisit,        vm.child),

            visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm),

            visit(ViewModel::Callbacks::Hook::BeforeVisit,       old_child),
            visit(ViewModel::Callbacks::Hook::BeforeDeserialize, old_child),
            visit(ViewModel::Callbacks::Hook::OnChange,          old_child),
            visit(ViewModel::Callbacks::Hook::AfterDeserialize,  old_child),
            visit(ViewModel::Callbacks::Hook::AfterVisit,        old_child),

            visit(ViewModel::Callbacks::Hook::OnChange,          vm),

            visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
            visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),
          ])
      end
    end

    describe 'with parent and children test models' do
      include ViewModelSpecHelpers::ParentAndHasManyChildren

      def new_model
        model_class.new(name: 'a', children: [child_model_class.new(name: 'b'), child_model_class.new(name: 'c')])
      end

      let(:new_child_hash) { { '_type' => 'Child', 'name' => 'q' } }
      let(:new_child) { vm.children.detect { |c| c.name == 'q' } }

      it 'calls hooks on replace associated' do
        old_child_1, old_child_2 = vm.children.sort_by(&:name)

        ctx = vm_deserialize_context(viewmodel_class)

        vm.replace_associated(:children, [new_child_hash], deserialize_context: ctx)
        vm.model.reload

        value(callback.hook_trace).must_equal(
          [visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       new_child),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, new_child),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    new_child),
           visit(ViewModel::Callbacks::Hook::OnChange,          new_child),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  new_child),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        new_child),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       old_child_1),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, old_child_1),
           visit(ViewModel::Callbacks::Hook::OnChange,          old_child_1),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  old_child_1),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        old_child_1),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       old_child_2),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, old_child_2),
           visit(ViewModel::Callbacks::Hook::OnChange,          old_child_2),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  old_child_2),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        old_child_2),

           visit(ViewModel::Callbacks::Hook::OnChange,          vm),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),])
      end

      it 'calls hooks on append_associated' do
        ctx = vm_deserialize_context(viewmodel_class)

        vm.append_associated(:children, [new_child_hash], deserialize_context: ctx)
        vm.model.reload

        value(callback.hook_trace).must_equal(
          [visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       new_child),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, new_child),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    new_child),
           visit(ViewModel::Callbacks::Hook::OnChange,          new_child),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  new_child),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        new_child),

           visit(ViewModel::Callbacks::Hook::OnChange,          vm),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),])
      end

      it 'calls hooks on delete_associated' do
        old_child_1, = vm.children.sort_by(&:name)

        ctx = vm_deserialize_context(viewmodel_class)

        vm.delete_associated(:children, old_child_1.id, deserialize_context: ctx)
        vm.model.reload

        value(callback.hook_trace).must_equal(
          [visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),
           visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm),

           visit(ViewModel::Callbacks::Hook::BeforeVisit,       old_child_1),
           visit(ViewModel::Callbacks::Hook::BeforeDeserialize, old_child_1),
           visit(ViewModel::Callbacks::Hook::OnChange,          old_child_1),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  old_child_1),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        old_child_1),

           visit(ViewModel::Callbacks::Hook::OnChange,          vm),
           visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
           visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),])
      end
    end

    describe 'with list test model' do
      include ViewModelSpecHelpers::List

      def new_model
        model_class.new(name: 'a', next: model_class.new(name: 'b', next: model_class.new(name: 'c')))
      end

      it 'calls hooks deeply on delete' do
        child = vm.next
        # grandchild = child.next

        alter_by_view!(viewmodel_class, vm.model) do |view, _refs|
          view['next'] = nil
        end

        value(callback.hook_trace).must_equal(
          [
            visit(ViewModel::Callbacks::Hook::BeforeVisit,       vm),
            visit(ViewModel::Callbacks::Hook::BeforeDeserialize, vm),
            visit(ViewModel::Callbacks::Hook::BeforeValidate,    vm),

            visit(ViewModel::Callbacks::Hook::BeforeVisit,       child),
            visit(ViewModel::Callbacks::Hook::BeforeDeserialize, child),
            visit(ViewModel::Callbacks::Hook::OnChange,          child),
            visit(ViewModel::Callbacks::Hook::AfterDeserialize,  child),
            visit(ViewModel::Callbacks::Hook::AfterVisit,        child),

            visit(ViewModel::Callbacks::Hook::OnChange,          vm),
            visit(ViewModel::Callbacks::Hook::AfterDeserialize,  vm),
            visit(ViewModel::Callbacks::Hook::AfterVisit,        vm),
          ])
        ## At present, children aren't deeplyvisited on delete.
        # visit(ViewModel::Callbacks::Hook::BeforeVisit,       grandchild),
        # visit(ViewModel::Callbacks::Hook::BeforeDeserialize, grandchild),
        # visit(ViewModel::Callbacks::Hook::OnChange,          grandchild),
        # visit(ViewModel::Callbacks::Hook::AfterDeserialize,  grandchild),
        # visit(ViewModel::Callbacks::Hook::AfterVisit,        grandchild)
      end
    end
  end

  describe 'with parent and child test models' do
    include ViewModelSpecHelpers::ParentAndHasOneChild

    def new_model
      model_class.new(name: 'a', child: child_model_class.new(name: 'b'))
    end

    describe 'view specific callbacks' do
      class ViewSpecificCallback
        include ViewModel::Callbacks
        attr_reader :models, :children

        def initialize
          @models = []
          @children = []
        end

        before_visit('Model') do
          models << view
        end

        before_visit('Child') do
          children << view
        end
      end

      let(:callback) { ViewSpecificCallback.new }

      it 'calls view specific callbacks' do
        serialize(vm)
        value(callback.models).must_equal([vm])
        value(callback.children).must_equal([vm.child])
      end
    end
  end

  describe 'with single test model' do
    include ViewModelSpecHelpers::Single

    def new_model
      model_class.new(name: 'a')
    end

    describe 'multiple callbacks on the same hook' do
      class TwoCallbacks
        include ViewModel::Callbacks

        attr_reader :events

        def initialize
          @events = []
        end

        before_visit { events << :a }
        before_visit { events << :b }
      end

      let(:callback) { TwoCallbacks.new }

      it 'calls view specific callbacks' do
        serialize(vm)
        value(callback.events).must_equal([:a, :b])
      end
    end

    describe 'callback inheritance' do
      class ParentCallback
        include ViewModel::Callbacks

        attr_reader :a

        def initialize
          @a = 0
        end

        def a!
          @a += 1
        end

        before_visit { a! }
      end

      class ChildCallback < ParentCallback
        attr_reader :b

        def initialize
          super
          @b = 0
        end

        def b!
          @b += 1
        end

        before_visit { b! }
      end

      let(:callback) { ChildCallback.new }

      it 'calls view specific callbacks' do
        serialize(vm)
        value(callback.a).must_equal(1)
        value(callback.b).must_equal(1)
      end
    end

    describe 'callback that raises' do
      class Crash < RuntimeError; end
      class CallbackCrasher
        include ViewModel::Callbacks

        before_visit do
          raise Crash.new
        end
      end

      let(:callback) { CallbackCrasher.new }

      it 'raises the callback error' do
        proc { serialize(vm) }.must_raise(Crash)
      end

      describe 'with an access control that rejects' do
        def vm_serialize_context(viewmodel_class, **args)
          super(viewmodel_class, access_control: ViewModel::AccessControl.new, **args)
        end

        it 'fails access control first' do
          proc { serialize(vm) }.must_raise(ViewModel::AccessControlError)
        end

        describe 'and a view-mutating callback that crashes' do
          class MutatingCrasher < CallbackCrasher
            updates_view!
          end

          let(:callback) { MutatingCrasher.new }

          it 'raises the callback error first' do
            proc { serialize(vm) }.must_raise(Crash)
          end
        end
      end
    end

    describe 'multiple callbacks' do
      class RecordingCallback
        include ViewModel::Callbacks
        def initialize(events, name)
          @events = events
          @name = name
        end

        def record!
          @events << @name
        end

        before_visit { record! }
      end

      class UpdatingCallback < RecordingCallback
        updates_view!
      end

      let(:events) { [] }

      let(:callbacks) do
        [RecordingCallback.new(events, :a),
         UpdatingCallback.new(events, :b),
         RecordingCallback.new(events, :c),
         UpdatingCallback.new(events, :d),]
      end

      it 'calls callbacks in order specified partitioned by update' do
        serialize(vm)
        value(events).must_equal([:b, :d, :a, :c])
      end
    end

    describe 'provides details to the execution environment' do
      class EnvCallback
        include ViewModel::Callbacks
        attr_accessor :env_contents

        on_change do
          self.env_contents = {
            view: view,
            model: model,
            context: context,
            changes: changes,
          }
        end
      end

      let(:callback) { EnvCallback.new }

      it 'records the environment as expected' do
        ctx = vm_deserialize_context(viewmodel_class)

        alter_by_view!(viewmodel_class, vm.model, deserialize_context: ctx) do |view, _refs|
          view['name'] = 'q'
        end
        value(callback.env_contents[:view]).must_equal(vm)
        value(callback.env_contents[:model]).must_equal(vm.model)
        value(callback.env_contents[:context]).must_equal(ctx)
        value(callback.env_contents[:changes]).must_equal(ViewModel::Changes.new(changed_attributes: ['name']))
      end
    end
  end
end
