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

    # Generate an ActiveModel-like keyword argument constructor.
    def generate_model_constructor(model_class, model_defaults)
      args = model_class.members
      params = args.map do |arg_name|
        "#{arg_name}: self.class.__constructor_default(:#{arg_name})"
      end

      <<-SRC
        def initialize(#{params.join(", ")})
          super(#{args.join(", ")})
        end
      SRC
    end

    let(:model_class) do
      mb = model_body
      mds = model_defaults

      model = Struct.new(*attributes.keys)
      constructor = generate_model_constructor(model, mds)
      model.class_eval(constructor)
      model.define_singleton_method(:__constructor_default) { |name| mds[name] }
      model.class_eval(&mb) if mb
      model
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

    # Default values for each model attribute, nil if absent
    let(:model_defaults) { {} }

    # attribute values used to instantiate the subject model and subject view (if not overridden)
    let(:subject_attributes) { {} }

    # attribute values used to instantiate the subject model
    let(:subject_model_attributes) { subject_attributes }

    # attribute values used to deserialize the subject view: these are expected to
    # deserialize to create a model equal to subject_model
    let(:subject_view_attributes) { subject_attributes }

    # Subject model to compare with or deserialize into
    let(:subject_model) do
      model_class.new(**subject_model_attributes)
    end

    # View that when deserialized into a new model will be equal to subject_model
    let(:subject_view) do
      view_base.merge(subject_view_attributes.stringify_keys)
    end

    # The expected result of serializing subject_model (depends on subject_view corresponding to subject_model)
    let(:expected_view) do
      view = subject_view.dup
      attribute_names.each do |model_attr_name, vm_attr_name|
        unless view.has_key?(vm_attr_name)
          expected_value = subject_model_attributes.fetch(model_attr_name) { model_defaults[model_attr_name] }
          view[vm_attr_name] = expected_value
        end
      end
      view
    end

    let(:access_control) { TestAccessControl.new(true, true, true) }

    let(:create_context) { TestDeserializeContext.new(access_control: access_control) }

    # Prime our simplistic `resolve_viewmodel` with the desired models to update
    let(:update_context) { TestDeserializeContext.new(targets: [subject_model], access_control: access_control) }

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
            vm = viewmodel_class.deserialize_from_view(subject_view, deserialize_context: create_context)
            assert_equal(subject_model, vm.model)
            refute(subject_model.equal?(vm.model))

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
            vm = viewmodel_class.deserialize_from_view(subject_view, deserialize_context: update_context)
            assert(subject_model.equal?(vm.model))

            assert_unchanged(vm)
          end
        end
      end
    end

    module CanSerialize
      def self.included(base)
        base.instance_eval do
          it 'can serialize to the expected view' do
            h = viewmodel_class.new(subject_model).to_hash
            assert_equal(expected_view, h)
          end
        end
      end
    end

    describe 'with simple attribute' do
      let(:attributes) { { simple: {} } }
      let(:subject_attributes) { { simple: "simple" } }

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it 'can be updated' do
        update_view = subject_view.merge('simple' => 'changed')

        vm = viewmodel_class.deserialize_from_view(update_view, deserialize_context: update_context)

        assert(subject_model.equal?(vm.model), 'returned model was not the same')
        assert_equal('changed', subject_model.simple)
        assert_edited(vm, changed_attributes: [:simple])
      end

      it 'rejects unknown attributes' do
        view = subject_view.merge('unknown' => 'illegal')
        ex = assert_raises(ViewModel::DeserializationError::UnknownAttribute) do
          viewmodel_class.deserialize_from_view(view, deserialize_context: create_context)
        end
        assert_equal('unknown', ex.attribute)
      end

      it 'rejects unknown versions' do
        view = subject_view.merge(ViewModel::VERSION_ATTRIBUTE => 100)
        ex = assert_raises(ViewModel::DeserializationError::SchemaVersionMismatch) do
          viewmodel_class.deserialize_from_view(view, deserialize_context: create_context)
        end
      end

      it 'edit checks when creating empty' do
        vm = viewmodel_class.deserialize_from_view(view_base, deserialize_context: create_context)
        refute(subject_model.equal?(vm.model), 'returned model was the same')
        assert_edited(vm, new: true)
      end
    end

    describe 'with validated simple attribute' do
      let(:attributes) { { validated: {} } }
      let(:subject_attributes) { { validated: "validated" } }

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
        update_view = subject_view.merge('validated' => 'naughty')

        ex = assert_raises(ViewModel::DeserializationError::Validation) do
          viewmodel_class.deserialize_from_view(update_view, deserialize_context: update_context)
        end
        assert_equal('validated', ex.attribute)
        assert_equal('was naughty', ex.reason)
      end
    end

    describe 'with renamed attribute' do
      let(:attributes) { { modelname: { as: :viewname } } }
      let(:subject_model_attributes) { { modelname: 'value' } }
      let(:subject_view_attributes)  { { viewname: 'value' } }

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it 'makes attributes available on their new names' do
        value(subject_model.modelname).must_equal('value')
        vm = viewmodel_class.new(subject_model)
        value(vm.viewname).must_equal('value')
      end
    end

    describe 'with formatted attribute' do
      let(:attributes) { { moment: { format: IknowParams::Serializer::Time } } }
      let(:moment) { 1.week.ago.change(usec: 0) }
      let(:subject_model_attributes) { { moment: moment } }
      let(:subject_view_attributes)  { { moment: moment.iso8601 } }

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it 'raises correctly on an unparseable value' do
        bad_view = subject_view.merge('moment' => 'not a timestamp')
        ex = assert_raises(ViewModel::DeserializationError::Validation) do
          viewmodel_class.deserialize_from_view(bad_view, deserialize_context: create_context)
        end
        assert_equal('moment', ex.attribute)
        assert_match(/could not be deserialized because.*Time/, ex.detail)
      end

      it 'raises correctly on an undeserializable value' do
        bad_model = subject_model.tap { |m| m.moment = 2.7 }
        ex = assert_raises(ViewModel::SerializationError) do
          viewmodel_class.new(bad_model).to_hash
        end
        assert_match(/Could not serialize invalid value.*'moment'.*Incorrect type/, ex.detail)
      end
    end

    describe 'with read-only attribute' do
      let(:attributes) { { read_only: { read_only: true } } }
      let(:model_defaults) { { read_only: 'immutable' } }
      let(:subject_attributes) { { read_only: 'immutable' } }

      describe 'asserting the default' do
        include CanSerialize
        include CanDeserializeToExisting

        it 'deserializes to new with the attribute' do
          vm = viewmodel_class.deserialize_from_view(subject_view, deserialize_context: create_context)
          assert_equal(subject_model, vm.model)
          refute(subject_model.equal?(vm.model))
          assert_edited(vm, new: true)
        end

        it 'deserializes to new without the attribute' do
          new_view = subject_view.tap { |v| v.delete('read_only') }
          vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: create_context)
          assert_equal(subject_model, vm.model)
          refute(subject_model.equal?(vm.model))
          assert_edited(vm, new: true)
        end
      end

      describe 'attempting a change' do
        let(:update_view) { subject_view.merge('read_only' => 'attempted change') }

        it 'rejects deserialize from new' do
          ex = assert_raises(ViewModel::DeserializationError::ReadOnlyAttribute) do
            viewmodel_class.deserialize_from_view(update_view, deserialize_context: create_context)
          end
          assert_equal('read_only', ex.attribute)
        end

        it 'rejects update' do
          ex = assert_raises(ViewModel::DeserializationError::ReadOnlyAttribute) do
            viewmodel_class.deserialize_from_view(update_view, deserialize_context: update_context)
          end
          assert_equal('read_only', ex.attribute)
        end
      end
    end

    describe 'with read-only write-once attribute' do
      let(:attributes) { { write_once: { read_only: true, write_once: true } } }
      let(:subject_attributes) { { write_once: 'frozen' } }
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
        new_view = subject_view.merge('write_once' => 'written')
        ex = assert_raises(ViewModel::DeserializationError::ReadOnlyAttribute) do
          viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)
        end
        assert_equal('write_once', ex.attribute)
      end
    end

    describe 'with unspecified attributes falling back to the model default' do
      let(:attributes) { { value: {} } }
      let(:model_defaults) { { value: 5 } }
      let(:subject_view_attributes)  { { } }
      let(:subject_model_attributes) { { value: 5 } }

      it 'can deserialize to a new model' do
        vm = viewmodel_class.deserialize_from_view(subject_view, deserialize_context: create_context)
        assert_equal(subject_model, vm.model)
        refute(subject_model.equal?(vm.model))
        assert_edited(vm, new: true, changed_attributes: [])
      end
    end

    describe 'with model defaults being asserted' do
      let(:attributes) { { value: {} } }
      let(:model_defaults) { { value: 5 } }
      let(:subject_attributes) { { value: 5 } }

      include CanDeserializeToNew
    end

    describe 'with custom serialization' do
      let(:attributes)           { { overridden: {} } }
      let(:subject_model_attributes) { { overridden: 5 } }
      let(:subject_view_attributes)  { { overridden: 10 } }

      let(:viewmodel_body) do
        ->(_x) do
          def serialize_overridden(json, serialize_context:)
            json.overridden model.overridden.try { |o| o * 2 }
          end

          def deserialize_overridden(value, references:, deserialize_context:)
            before_value = model.overridden
            model.overridden = value.try { |v| Integer(v) / 2 }
            attribute_changed!(:overridden) unless !new_model? && before_value == model.overridden
          end
        end
      end

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it 'can be updated' do
        new_view = subject_view.merge('overridden' => '20')

        vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)

        assert(subject_model.equal?(vm.model), 'returned model was not the same')
        assert_equal(10, subject_model.overridden)

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
        let(:subject_nested_model) { nested_model_class.new('member') }
        let(:subject_nested_view)  { view_base.merge('_type' => 'Nested', 'member' => 'member') }

        let(:attributes) { { simple: {}, nested: { using: nested_viewmodel_class } } }

        let(:subject_view_attributes)  { { nested: subject_nested_view } }
        let(:subject_model_attributes) { { nested: subject_nested_model } }

        let(:update_context) do
          TestDeserializeContext.new(
            targets: [subject_model, subject_nested_model],
            access_control: access_control)
        end

        include CanSerialize

        it 'can deserialize to a new model' do
          vm = viewmodel_class.deserialize_from_view(subject_view, deserialize_context: create_context)
          assert_equal(subject_model, vm.model)
          refute(subject_model.equal?(vm.model))

          assert_equal(subject_nested_model, vm.model.nested)
          refute(subject_nested_model.equal?(vm.model.nested))

          assert_edited(vm, new: true, changed_attributes: ['nested'], changed_nested_children: true)
        end

        include CanDeserializeToExisting

        it 'can update the nested value' do
          new_view = subject_view.merge('nested' => subject_nested_view.merge('member' => 'changed'))

          vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)

          assert(subject_model.equal?(vm.model), 'returned model was not the same')
          assert(subject_nested_model.equal?(vm.model.nested), 'returned nested model was not the same')

          assert_equal('changed', subject_model.nested.member)

          assert_unchanged(vm)

          # The parent is itself not `changed?`, but it must record that its children are
          change = access_control.all_changes(vm.to_reference)[0]
          assert_equal(ViewModel::Changes.new(changed_nested_children: true), change)

          assert_edited(vm.nested, changed_attributes: [:member])
        end

        it 'can replace the nested value' do
          # The value will be unified if it is different after deserialization
          new_view = subject_view.merge('nested' => subject_nested_view.merge('member' => 'changed'))

          partial_update_context = TestDeserializeContext.new(targets: [subject_model],
                                                              access_control: access_control)

          vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: partial_update_context)

          assert(subject_model.equal?(vm.model), 'returned model was not the same')
          refute(subject_nested_model.equal?(vm.model.nested), 'returned nested model was the same')

          assert_edited(vm, new: false, changed_attributes: [:nested], changed_nested_children: true)
          assert_edited(vm.nested, new: true, changed_attributes: [:member])
        end
      end

      describe 'with array of nested viewmodel' do
        let(:subject_nested_model_1) { nested_model_class.new('member1') }
        let(:subject_nested_view_1)  { view_base.merge('_type' => 'Nested', 'member' => 'member1') }

        let(:subject_nested_model_2) { nested_model_class.new('member2') }
        let(:subject_nested_view_2)  { view_base.merge('_type' => 'Nested', 'member' => 'member2') }

        let(:attributes) { { simple: {}, nested: { using: nested_viewmodel_class, array: true } } }

        let(:subject_view_attributes)  { { nested: [subject_nested_view_1, subject_nested_view_2] } }
        let(:subject_model_attributes) { { nested: [subject_nested_model_1, subject_nested_model_2] } }

        let(:update_context) {
          TestDeserializeContext.new(targets: [subject_model, subject_nested_model_1, subject_nested_model_2],
                                     access_control: access_control)
        }

        include CanSerialize

        it 'can deserialize to a new model' do
          vm = viewmodel_class.deserialize_from_view(subject_view, deserialize_context: create_context)
          assert_equal(subject_model, vm.model)
          refute(subject_model.equal?(vm.model))

          assert_edited(vm, new: true, changed_attributes: ['nested'], changed_nested_children: true)
        end

        include CanDeserializeToExisting

        it 'rejects change to attribute' do
          new_view = subject_view.merge('nested' => 'terrible')
          ex = assert_raises(ViewModel::DeserializationError::InvalidAttributeType) do
            viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)
          end
          assert_equal('nested', ex.attribute)
          assert_equal('Array',  ex.expected_type)
          assert_equal('String', ex.provided_type)
        end

        it 'can edit a nested value' do
          subject_view['nested'][0]['member'] = 'changed'
          vm = viewmodel_class.deserialize_from_view(subject_view, deserialize_context: update_context)
          assert(subject_model.equal?(vm.model), 'returned model was not the same')
          assert_equal(2, vm.model.nested.size)
          assert(subject_nested_model_1.equal?(vm.model.nested[0]))
          assert(subject_nested_model_2.equal?(vm.model.nested[1]))

          assert_unchanged(vm)

          # The parent is itself not `changed?`, but it must record that its children are
          change = access_control.all_changes(vm.to_reference)[0]
          assert_equal(ViewModel::Changes.new(changed_nested_children: true), change)

          assert_edited(vm.nested[0], changed_attributes: [:member])
        end

        it 'can append a nested value' do
          subject_view['nested'] << view_base.merge('_type' => 'Nested', 'member' => 'member3')

          vm = viewmodel_class.deserialize_from_view(subject_view, deserialize_context: update_context)

          assert(subject_model.equal?(vm.model), 'returned model was not the same')
          assert_equal(3, vm.model.nested.size)
          assert(subject_nested_model_1.equal?(vm.model.nested[0]))
          assert(subject_nested_model_2.equal?(vm.model.nested[1]))

          vm.model.nested.each_with_index do |nvm, i|
            assert_equal("member#{i + 1}", nvm.member)
          end

          assert_edited(vm, changed_attributes: [:nested], changed_nested_children: true)
          assert_edited(vm.nested[2], new: true, changed_attributes: [:member])
        end
      end
    end
  end
end
