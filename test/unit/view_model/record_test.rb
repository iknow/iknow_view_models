require_relative "../../helpers/test_access_control.rb"

require "minitest/autorun"
require 'minitest/unit'

require "view_model"
require "view_model/record"

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

    def initialize(**rest)
      super(**rest)
    end
  end

  class TestSerializeContext < ViewModel::SerializeContext
    def initialize(**rest)
      super(**rest)
    end
  end

  class TestViewModel < ViewModel::Record
    self.unregistered = true

    def self.deserialize_context_class
      TestDeserializeContext
    end

    def self.serialize_context_class
      TestSerializeContext
    end

    def self.resolve_viewmodel(type, version, id, new, view_hash, deserialize_context:)
      if target_model = deserialize_context.targets.shift
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
        self.view_name   = "Model"
        self.model_class = mc

        attrs.each { |a, opts| attribute(a, **opts) }

        class_eval(&vmb) if vmb
      end
    end

    let(:view_base) do
      {
        "_type"      => "Model",
        "_version"   => 1
      }
    end

    let(:default_values) { {} }
    let(:default_view_values) { default_values }
    let(:default_model_values) { default_values }

    let(:default_view) do
      attributes.keys.each_with_object(view_base.dup) do |attr_name, view|
        view[attr_name.to_s] = default_view_values.fetch(attr_name, attr_name.to_s)
      end
    end

    let(:default_model) do
      attr_values = attributes.keys.map do |attr_name|
        default_model_values.fetch(attr_name, attr_name.to_s)
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
          it "can deserialize to a new model" do
            vm = viewmodel_class.deserialize_from_view(default_view, deserialize_context: create_context)
            assert_equal(default_model, vm.model)
            refute(default_model.equal?(vm.model))

            assert_edited(vm, new: true, changed_attributes: attributes.keys)
          end
        end
      end
    end

    module CanDeserializeToExisting
      def self.included(base)
        base.instance_eval do
          it "can deserialize to existing model with no changes" do
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
          it "can serialize to the expected view" do
            h = viewmodel_class.new(default_model).to_hash
            assert_equal(default_view, h)
          end
        end
      end
    end

    describe "with simple attribute" do
      let(:attributes) { { simple: {} } }
      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it "can be updated" do
        new_view = default_view.merge("simple" => "changed")

        vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)

        assert(default_model.equal?(vm.model), "returned model was not the same")
        assert_equal("changed", default_model.simple)
        assert_edited(vm, changed_attributes: [:simple])
      end

      it "rejects unknown attributes" do
        view = default_view.merge("unknown" => "illegal")
        ex = assert_raises(ViewModel::DeserializationError) do
          viewmodel_class.deserialize_from_view(view, deserialize_context: create_context)
        end
        assert_match(/Illegal attribute/, ex.message)
      end

      it "can prune an attribute" do
        h = viewmodel_class.new(default_model).to_hash(serialize_context: TestSerializeContext.new(prune: [:simple]))
        pruned_view = default_view.tap { |v| v.delete("simple") }
        assert_equal(pruned_view, h)
      end

      it "edit checks when creating empty" do
        vm = viewmodel_class.deserialize_from_view(view_base, deserialize_context: create_context)
        refute(default_model.equal?(vm.model), "returned model was the same")
        assert_edited(vm, new: true)
      end
    end

    describe "with validated simple attribute" do
      let(:attributes) { { validated: {} } }
      let(:viewmodel_body) do
        ->(x) do
          def validate!
            if validated == "naughty"
              raise ViewModel::DeserializationError::Validation.new(
                      "Validation failed: validated was naughty",
                      self.blame_reference)
            end
          end
        end
      end

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it "rejects update when validation fails" do
        new_view = default_view.merge("validated" => "naughty")

        ex = assert_raises(ViewModel::DeserializationError::Validation) do
          viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)
        end

        assert_match(/Validation failed: validated was naughty/, ex.message)
      end
    end

    describe "with read-only attribute" do
      let(:attributes) { { read_only: { read_only: true } } }

      include CanSerialize
      include CanDeserializeToExisting

      it "deserializes to new without the attribute" do
        new_view = default_view.tap { |v| v.delete("read_only") }
        vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: create_context)
        refute(default_model.equal?(vm.model))
        assert_nil(vm.model.read_only)
        assert_edited(vm, new: true)
      end

      it "rejects deserialize from new" do
        ex = assert_raises(ViewModel::DeserializationError) do
          viewmodel_class.deserialize_from_view(default_view, deserialize_context: create_context)
        end
        assert_match(/Cannot edit read only/, ex.message)
      end

      it "rejects update if changed" do
        new_view = default_view.merge("read_only" => "written")
        ex = assert_raises(ViewModel::DeserializationError) do
          viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)
        end

        assert_match(/Cannot edit read only/, ex.message)
      end
    end

    describe "with read-only write-once attribute" do
      let(:attributes) { { write_once: { read_only: true, write_once: true } } }
      let(:model_body) do
        ->(x) do
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

      it "rejects change to attribute" do
        new_view = default_view.merge("write_once" => "written")
        ex = assert_raises(ViewModel::DeserializationError) do
          viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)
        end

        assert_match(/Cannot edit read only/, ex.message)
      end
    end

    describe "with custom serialization" do
      let(:attributes)           { { overridden: {} } }
      let(:default_view_values)  { { overridden: 10 } }
      let(:default_model_values) { { overridden: 5 } }
      let(:viewmodel_body) do
        ->(x) do
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

      it "can be updated" do
        new_view = default_view.merge("overridden" => "20")

        vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)

        assert(default_model.equal?(vm.model), "returned model was not the same")
        assert_equal(10, default_model.overridden)

        assert_edited(vm, changed_attributes: [:overridden])
      end
    end

    describe "with optional attributes" do
      let(:attributes) { { optional: { optional: true } } }

      include CanDeserializeToNew
      include CanDeserializeToExisting

      it "can serialize with the optional attribute" do
        h = viewmodel_class.new(default_model).to_hash(serialize_context: TestSerializeContext.new(include: [:optional]))
        assert_equal(default_view, h)
      end

      it "can serialize without the optional attribute" do
        h = viewmodel_class.new(default_model).to_hash
        pruned_view = default_view.tap { |v| v.delete("optional") }
        assert_equal(pruned_view, h)
      end
    end

    Nested = Struct.new(:member)

    class NestedView < TestViewModel
      self.view_name = "Nested"
      self.model_class = Nested
      attribute :member
    end

    describe "with nested viewmodel" do
      let(:default_nested_model) { Nested.new("member") }
      let(:default_nested_view)  { view_base.merge("_type" => "Nested", "member" => "member") }

      let(:attributes) {{ simple: {}, nested: { using: NestedView } }}

      let(:default_view_values)  { { nested: default_nested_view } }
      let(:default_model_values) { { nested: default_nested_model } }

      let(:update_context) { TestDeserializeContext.new(targets: [default_model, default_nested_model],
                                                        access_control: access_control) }

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it "can update the nested value" do
        new_view = default_view.merge("nested" => default_nested_view.merge("member" => "changed"))

        vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)

        assert(default_model.equal?(vm.model), "returned model was not the same")
        assert(default_nested_model.equal?(vm.model.nested), "returned nested model was not the same")

        assert_equal("changed", default_model.nested.member)

        assert_unchanged(vm)
        assert_edited(vm.nested, changed_attributes: [:member])
      end

      it "can replace the nested value" do
        # The value will be unified if it is different after deserialization
        new_view = default_view.merge("nested" => default_nested_view.merge("member" => "changed"))

        partial_update_context = TestDeserializeContext.new(targets: [default_model],
                                                            access_control: access_control)

        vm = viewmodel_class.deserialize_from_view(new_view, deserialize_context: partial_update_context)

        assert(default_model.equal?(vm.model), "returned model was not the same")
        refute(default_nested_model.equal?(vm.model.nested), "returned nested model was the same")

        assert_edited(vm, new: false, changed_attributes: [:nested])
        assert_edited(vm.nested, new: true, changed_attributes: [:member])
      end

      it "can prune attributes in the nested value" do
        h = viewmodel_class.new(default_model).to_hash(
          serialize_context: TestSerializeContext.new(prune: { nested: [:member] }))

        pruned_view = default_view.tap { |v| v["nested"].delete("member") }
        assert_equal(pruned_view, h)
      end
    end

    describe "with array of nested viewmodel" do
      let(:default_nested_model_1) { Nested.new("member1") }
      let(:default_nested_view_1)  { view_base.merge("_type" => "Nested", "member" => "member1") }

      let(:default_nested_model_2) { Nested.new("member2") }
      let(:default_nested_view_2)  { view_base.merge("_type" => "Nested", "member" => "member2") }

      let(:attributes) {{ simple: {}, nested: { using: NestedView, array: true } }}

      let(:default_view_values)  { { nested: [default_nested_view_1, default_nested_view_2] } }
      let(:default_model_values) { { nested: [default_nested_model_1, default_nested_model_2] } }

      let(:update_context) {
        TestDeserializeContext.new(targets: [default_model, default_nested_model_1, default_nested_model_2],
                                   access_control: access_control)
      }

      include CanSerialize
      include CanDeserializeToNew
      include CanDeserializeToExisting

      it "rejects change to attribute" do
        new_view = default_view.merge("nested" => "terrible")
        ex = assert_raises(ViewModel::DeserializationError) do
          viewmodel_class.deserialize_from_view(new_view, deserialize_context: update_context)
        end

        assert_match(/Expected 'nested' to be 'Array'/, ex.message)
      end

      it "can edit a nested value" do
        default_view["nested"][0]["member"] = "changed"
        vm = viewmodel_class.deserialize_from_view(default_view, deserialize_context: update_context)
        assert(default_model.equal?(vm.model), "returned model was not the same")
        assert_equal(2, vm.model.nested.size)
        assert(default_nested_model_1.equal?(vm.model.nested[0]))
        assert(default_nested_model_2.equal?(vm.model.nested[1]))

        assert_unchanged(vm)
        assert_edited(vm.nested[0], changed_attributes: [:member])
      end

      it "can append a nested value" do
        default_view["nested"] << view_base.merge("_type" => "Nested", "member" => "member3")

        vm = viewmodel_class.deserialize_from_view(default_view, deserialize_context: update_context)

        assert(default_model.equal?(vm.model), "returned model was not the same")
        assert_equal(3, vm.model.nested.size)
        assert(default_nested_model_1.equal?(vm.model.nested[0]))
        assert(default_nested_model_2.equal?(vm.model.nested[1]))

        vm.model.nested.each_with_index do |nvm, i|
          assert_equal("member#{i+1}", nvm.member)
        end

        assert_edited(vm, changed_attributes: [:nested])
        assert_edited(vm.nested[2], new: true, changed_attributes: [:member])
      end
    end
  end

end
