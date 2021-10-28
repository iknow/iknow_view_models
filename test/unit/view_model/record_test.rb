# frozen_string_literal: true

require_relative '../../helpers/test_access_control'

require 'minitest/autorun'
require 'minitest/unit'

require 'view_model'
require 'view_model/record'

class ViewModel::RecordTest < ActiveSupport::TestCase
  using ViewModel::Utils::Collections
  extend Minitest::Spec::DSL

  class TestDeserializeContext < ViewModel::DeserializeContext
    class SharedContext < ViewModel::DeserializeContext::SharedContext
      attr_reader :targets

      def initialize(targets: [], **rest)
        super(**rest)
        @targets = targets
      end
    end

    def self.shared_context_class
      SharedContext
    end

    delegate :targets, to: :shared_context
  end

  class TestSerializeContext < ViewModel::SerializeContext
  end

  class TestViewModel < ViewModel::Record
    self.unregistered = true

    def self.deserialize_context_class
      TestDeserializeContext
    end

    def self.serialize_context_class
      TestSerializeContext
    end

    def self.resolve_viewmodel(_metadata, _view_hash, deserialize_context:)
      if (target_model = deserialize_context.targets.shift)
        self.new(target_model)
      else
        self.for_new_model
      end
    end
  end

  describe 'VM::Record' do
    let(:attributes)     { {} }
    let(:model_body)     { nil }
    let(:viewmodel_body) { nil }

    let(:model_class) do
      mb = model_body
      Struct.new(*attributes.keys) do
        class_eval(&mb) if mb
      end
    end

    let(:viewmodel_class) do
      mc    = model_class
      attrs = attributes
      vmb   = viewmodel_body
      Class.new(TestViewModel) do
        # Avoid the need for teardown. Registration is only necessary for
        # associations.
        self.unregistered = true

        self.view_name   = 'Model'
        self.model_class = mc

        attrs.each { |a, opts| attribute(a, **opts) }

        class_eval(&vmb) if vmb
      end
    end

    let(:view_base) do
      {
        '_type'      => 'Model',
        '_version'   => 1,
      }
    end

    let(:attribute_names) do
      attributes.map do |model_attr_name, opts|
        vm_attr_name = (opts[:as] || model_attr_name).to_s
        [model_attr_name.to_s, vm_attr_name]
      end
    end

    let(:default_values) { {} }
    let(:default_view_values) { default_values }
    let(:default_model_values) { default_values }

    let(:default_view) do
      attribute_names.each_with_object(view_base.dup) do |(model_attr_name, vm_attr_name), view|
        view[vm_attr_name] = default_view_values.fetch(vm_attr_name.to_sym, model_attr_name)
      end
    end

    let(:default_model) do
      attr_values = attribute_names.map do |model_attr_name, _vm_attr_name|
        default_model_values.fetch(model_attr_name.to_sym, model_attr_name)
      end
      model_class.new(*attr_values)
    end

    let(:access_control) { TestAccessControl.new(true, true, true) }

    let(:create_context) { TestDeserializeContext.new(access_control: access_control) }

    # Prime our simplistic `resolve_viewmodel` with the desired models to update
    let(:update_context) { TestDeserializeContext.new(targets: [default_model], access_control: access_control) }

    def assert_edited(vm, **changes)
      ref = vm.to_reference
      assert(access_control.visible_checks.include?(ref))
      assert(access_control.editable_checks.include?(ref))
      assert_equal([ViewModel::Changes.new(**changes)],
                   access_control.all_valid_edit_changes(ref))
    end

    def assert_unchanged(vm)
      ref = vm.to_reference
      assert(access_control.visible_checks.include?(ref))
      assert(access_control.editable_checks.include?(ref))
      assert_equal([], access_control.all_valid_edit_changes(ref))
    end

    module CanDeserializeToNew
      def self.included(base)
        base.instance_eval do
          it 'can deserialize to a new model' do
            vm = viewmodel_class.deserialize_from_view(default_view, deserialize_context: create_context)
            assert_equal(default_model, vm.model)
            refute(default_model.equal?(vm.model))

            all_view_attrs = attribute_names.map { |_mname, vname| vname }
            assert_edited(vm, new: true, changed_attributes: all_view_attrs)
          end
        end
      end
    end

    module CanDeserializeToExisting
      def self.included(base)
        base.instance_eval do
          it 'can deserialize to existing model with no changes' do
            vm = viewmodel_class.deserialize_from_view(default_view, deserialize_context: update_context)
            assert(default_model.equal?(vm.model))

            assert_unchanged(vm)
          end
        end
      end
    end

    module CanSerialize
      def self.included(base)
        base.instance_eval do
          it 'can serialize to the expected view' do
            h = viewmodel_class.new(default_model).to_hash
            assert_equal(default_view, h)
          end
        end
      end
    end

    describe 'with simple attribute' do
      let(:attributes) { { simple: {} } }
      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it 'can be updated' do
        new_view = default_view.merge('simple' => 'changed')

        vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)

        assert(default_model.equal?(vm.model), 'returned model was not the same')
        assert_equal('changed', default_model.simple)
        assert_edited(vm, changed_attributes: [:simple])
      end

      it 'rejects unknown attributes' do
        view = default_view.merge('unknown' => 'illegal')
        ex = assert_raises(ViewModel::DeserializationError::UnknownAttribute) do
          viewmodel_class.deserialize_from_view(view, deserialize_context: create_context)
        end
        assert_equal('unknown', ex.attribute)
      end

      it 'rejects unknown versions' do
        view = default_view.merge(ViewModel::VERSION_ATTRIBUTE => 100)
        ex = assert_raises(ViewModel::DeserializationError::SchemaVersionMismatch) do
          viewmodel_class.deserialize_from_view(view, deserialize_context: create_context)
        end
      end

      it 'edit checks when creating empty' do
        vm = viewmodel_class.deserialize_from_view(view_base, deserialize_context: create_context)
        refute(default_model.equal?(vm.model), 'returned model was the same')
        assert_edited(vm, new: true)
      end
    end

    describe 'with validated simple attribute' do
      let(:attributes) { { validated: {} } }
      let(:viewmodel_body) do
        ->(_x) do
          def validate!
            if validated == 'naughty'
              raise ViewModel::DeserializationError::Validation.new('validated', 'was naughty', nil, self.blame_reference)
            end
          end
        end
      end

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it 'rejects update when validation fails' do
        new_view = default_view.merge('validated' => 'naughty')

        ex = assert_raises(ViewModel::DeserializationError::Validation) do
          viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)
        end
        assert_equal('validated', ex.attribute)
        assert_equal('was naughty', ex.reason)
      end
    end

    describe 'with renamed attribute' do
      let(:attributes) { { modelname: { as: :viewname } } }
      let(:default_model_values) { { modelname: 'value' } }
      let(:default_view_values)  { { viewname: 'value' } }

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it 'makes attributes available on their new names' do
        value(default_model.modelname).must_equal('value')
        vm = viewmodel_class.new(default_model)
        value(vm.viewname).must_equal('value')
      end
    end

    describe 'with formatted attribute' do
      let(:attributes) { { moment: { format: IknowParams::Serializer::Time } } }
      let(:moment) { 1.week.ago.change(usec: 0) }
      let(:default_model_values) { { moment: moment } }
      let(:default_view_values)  { { moment: moment.iso8601 } }

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it 'raises correctly on an unparseable value' do
        bad_view = default_view.tap { |v| v['moment'] = 'not a timestamp' }
        ex = assert_raises(ViewModel::DeserializationError::Validation) do
          viewmodel_class.deserialize_from_view(bad_view, deserialize_context: create_context)
        end
        assert_equal('moment', ex.attribute)
        assert_match(/could not be deserialized because.*Time/, ex.detail)
      end

      it 'raises correctly on an undeserializable value' do
        bad_model = default_model.tap { |m| m.moment = 2.7 }
        ex = assert_raises(ViewModel::SerializationError) do
          viewmodel_class.new(bad_model).to_hash
        end
        assert_match(/Could not serialize invalid value.*'moment'.*Incorrect type/, ex.detail)
      end
    end

    describe 'with read-only attribute' do
      let(:attributes) { { read_only: { read_only: true } } }

      include CanSerialize
      include CanDeserializeToExisting

      it 'deserializes to new without the attribute' do
        new_view = default_view.tap { |v| v.delete('read_only') }
        vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: create_context)
        refute(default_model.equal?(vm.model))
        assert_nil(vm.model.read_only)
        assert_edited(vm, new: true)
      end

      it 'rejects deserialize from new' do
        ex = assert_raises(ViewModel::DeserializationError::ReadOnlyAttribute) do
          viewmodel_class.deserialize_from_view(default_view, deserialize_context: create_context)
        end
        assert_equal('read_only', ex.attribute)
      end

      it 'rejects update if changed' do
        new_view = default_view.merge('read_only' => 'written')
        ex = assert_raises(ViewModel::DeserializationError::ReadOnlyAttribute) do
          viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)
        end
        assert_equal('read_only', ex.attribute)
      end
    end

    describe 'with read-only write-once attribute' do
      let(:attributes) { { write_once: { read_only: true, write_once: true } } }
      let(:model_body) do
        ->(_x) do
          # For the purposes of testing, we assume a record is new and can be
          # written once to if write_once is nil. We will never write a nil.
          def new_record?
            write_once.nil?
          end
        end
      end

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it 'rejects change to attribute' do
        new_view = default_view.merge('write_once' => 'written')
        ex = assert_raises(ViewModel::DeserializationError::ReadOnlyAttribute) do
          viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)
        end
        assert_equal('write_once', ex.attribute)
      end
    end

    describe 'with custom serialization' do
      let(:attributes)           { { overridden: {} } }
      let(:default_view_values)  { { overridden: 10 } }
      let(:default_model_values) { { overridden: 5 } }
      let(:viewmodel_body) do
        ->(_x) do
          def serialize_overridden(json, serialize_context:)
            json.overridden model.overridden.try { |o| o * 2 }
          end

          def deserialize_overridden(value, references:, deserialize_context:)
            before_value = model.overridden
            model.overridden = value.try { |v| Integer(v) / 2 }
            attribute_changed!(:overridden) unless before_value == model.overridden
          end
        end
      end

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it 'can be updated' do
        new_view = default_view.merge('overridden' => '20')

        vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)

        assert(default_model.equal?(vm.model), 'returned model was not the same')
        assert_equal(10, default_model.overridden)

        assert_edited(vm, changed_attributes: [:overridden])
      end
    end

    describe 'nesting' do
      let(:nested_model_class) do
        klass = Struct.new(:member)
        Object.const_set(:Nested, klass)
        klass
      end

      let(:nested_viewmodel_class) do
        mc = nested_model_class
        klass = Class.new(TestViewModel) do
          self.view_name = 'Nested'
          self.model_class = mc
          attribute :member
        end
        Object.const_set(:NestedView, klass)
        klass
      end

      def teardown
        Object.send(:remove_const, :Nested)
        Object.send(:remove_const, :NestedView)
        ActiveSupport::Dependencies::Reference.clear!
        super
      end

      describe 'with nested viewmodel' do
        let(:default_nested_model) { nested_model_class.new('member') }
        let(:default_nested_view)  { view_base.merge('_type' => 'Nested', 'member' => 'member') }

        let(:attributes) { { simple: {}, nested: { using: nested_viewmodel_class } } }

        let(:default_view_values)  { { nested: default_nested_view } }
        let(:default_model_values) { { nested: default_nested_model } }

        let(:update_context) do
          TestDeserializeContext.new(targets: [default_model, default_nested_model],
                                     access_control: access_control)
        end

        include CanSerialize
        include CanDeserializeToNew
        include CanDeserializeToExisting

        it 'can update the nested value' do
          new_view = default_view.merge('nested' => default_nested_view.merge('member' => 'changed'))

          vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)

          assert(default_model.equal?(vm.model), 'returned model was not the same')
          assert(default_nested_model.equal?(vm.model.nested), 'returned nested model was not the same')

          assert_equal('changed', default_model.nested.member)

          assert_unchanged(vm)
          assert_edited(vm.nested, changed_attributes: [:member])
        end

        it 'can replace the nested value' do
          # The value will be unified if it is different after deserialization
          new_view = default_view.merge('nested' => default_nested_view.merge('member' => 'changed'))

          partial_update_context = TestDeserializeContext.new(targets: [default_model],
                                                              access_control: access_control)

          vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: partial_update_context)

          assert(default_model.equal?(vm.model), 'returned model was not the same')
          refute(default_nested_model.equal?(vm.model.nested), 'returned nested model was the same')

          assert_edited(vm, new: false, changed_attributes: [:nested])
          assert_edited(vm.nested, new: true, changed_attributes: [:member])
        end
      end

      describe 'with array of nested viewmodel' do
        let(:default_nested_model_1) { nested_model_class.new('member1') }
        let(:default_nested_view_1)  { view_base.merge('_type' => 'Nested', 'member' => 'member1') }

        let(:default_nested_model_2) { nested_model_class.new('member2') }
        let(:default_nested_view_2)  { view_base.merge('_type' => 'Nested', 'member' => 'member2') }

        let(:attributes) { { simple: {}, nested: { using: nested_viewmodel_class, array: true } } }

        let(:default_view_values)  { { nested: [default_nested_view_1, default_nested_view_2] } }
        let(:default_model_values) { { nested: [default_nested_model_1, default_nested_model_2] } }

        let(:update_context) {
          TestDeserializeContext.new(targets: [default_model, default_nested_model_1, default_nested_model_2],
                                     access_control: access_control)
        }

        include CanSerialize
        include CanDeserializeToNew
        include CanDeserializeToExisting

        it 'rejects change to attribute' do
          new_view = default_view.merge('nested' => 'terrible')
          ex = assert_raises(ViewModel::DeserializationError::InvalidAttributeType) do
            viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)
          end
          assert_equal('nested', ex.attribute)
          assert_equal('Array',  ex.expected_type)
          assert_equal('String', ex.provided_type)
        end

        it 'can edit a nested value' do
          default_view['nested'][0]['member'] = 'changed'
          vm = viewmodel_class.deserialize_from_view(default_view, deserialize_context: update_context)
          assert(default_model.equal?(vm.model), 'returned model was not the same')
          assert_equal(2, vm.model.nested.size)
          assert(default_nested_model_1.equal?(vm.model.nested[0]))
          assert(default_nested_model_2.equal?(vm.model.nested[1]))

          assert_unchanged(vm)
          assert_edited(vm.nested[0], changed_attributes: [:member])
        end

        it 'can append a nested value' do
          default_view['nested'] << view_base.merge('_type' => 'Nested', 'member' => 'member3')

          vm = viewmodel_class.deserialize_from_view(default_view, deserialize_context: update_context)

          assert(default_model.equal?(vm.model), 'returned model was not the same')
          assert_equal(3, vm.model.nested.size)
          assert(default_nested_model_1.equal?(vm.model.nested[0]))
          assert(default_nested_model_2.equal?(vm.model.nested[1]))

          vm.model.nested.each_with_index do |nvm, i|
            assert_equal("member#{i + 1}", nvm.member)
          end

          assert_edited(vm, changed_attributes: [:nested])
          assert_edited(vm.nested[2], new: true, changed_attributes: [:member])
        end
      end
    end
  end
end
