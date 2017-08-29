require_relative "../../helpers/test_access_control.rb"

require "minitest/autorun"
require 'minitest/unit'

require "view_model"
require "view_model/record"

class ViewModel::RecordTest < ActiveSupport::TestCase

  Model = Struct.new(:simple, :overridden, :readonly, :writeonce, :recursive, :optional) do
    def new_record?
      writeonce.nil?
    end
  end

  class ModelView < ViewModel::Record
    self.model_class = Model
    self.view_name = "Model"

    attribute :simple
    attribute :overridden
    attribute :readonly,  read_only: true
    attribute :writeonce, read_only: true, write_once: true
    attribute :recursive, using: ModelView
    attribute :optional,  optional: true

    def serialize_overridden(json, serialize_context:)
      json.overridden model.overridden.try { |o| o * 2 }
    end

    def deserialize_overridden(value, references:, deserialize_context:)
      before_value = model.overridden
      model.overridden = value.try { |v| Integer(v) / 2 }
      attribute_changed!(:overridden) unless before_value == model.overridden
    end

    def validate!
      if simple == "naughty"
        raise ViewModel::DeserializationError::Validation.new(
                "Validation failed: simple was naughty",
                self.blame_reference)
      end
    end

    class DeserializeContext < ViewModel::DeserializeContext
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

    def self.deserialize_context_class
      DeserializeContext
    end

    class SerializeContext < ViewModel::SerializeContext
      def initialize(**rest)
        super(**rest)
      end
    end

    def self.serialize_context_class
      SerializeContext
    end

    def self.resolve_viewmodel(type, version, id, new, view_hash, deserialize_context:)
      if target_model = deserialize_context.targets.shift
        self.new(target_model)
      else
        self.for_new_model
      end
    end
  end

  def setup
    @model = Model.new("simple", 2, "readonly", "writeonce", Model.new("child"), "optional")

    @minimal_view = {
      "_type"    => "Model",
      "_version" => 1,
    }

    @view = {
      "_type"      => "Model",
      "_version"   => 1,
      "simple"     => "simple",
      "overridden" => 4,
      "optional"   => "optional",
      "readonly"   => "readonly",
      "writeonce"  => "writeonce",
      "recursive"  => {
        "_type"      => "Model",
        "_version"   => 1,
        "simple"     => "child",
        "overridden" => nil,
        "optional"   => nil,
        "readonly"   => nil,
        "writeonce"  => nil,
        "recursive"  => nil
      }
    }
  end

  def test_create_from_view
    @model.readonly = nil
    @view.delete("readonly")

    v = ModelView.deserialize_from_view(@view)
    m = v.model

    assert_equal(@model, m)
  end

  def test_create_bad_attribute
    @view["bad"] = 6
    ex = assert_raises(ViewModel::DeserializationError) do
      ModelView.deserialize_from_view(@view)
    end
    assert_match(/Illegal attribute/, ex.message)
  end

  def test_validation_failure_on_create
    @view["simple"] = "naughty"
    @view.delete("readonly")
    ex = assert_raises(ViewModel::DeserializationError::Validation) do
      ModelView.deserialize_from_view(@view)
    end
    assert_match(/Validation failed: simple was naughty/, ex.message)
  end

  def test_update_from_view
    # Prime our simplistic `resolve_viewmodel` with the desired models to update
    ctx = ModelView::DeserializeContext.new(targets: [@model, @model.recursive])

    @view["simple"] = "change"
    @view["recursive"]["simple"] = "morechange"

    v = ModelView.deserialize_from_view(@view, deserialize_context: ctx)

    assert_equal(@model, v.model)
    assert_equal("change", @model.simple)
    assert_equal("morechange", @model.recursive.simple)
  end

  def test_validation_failure_on_update
    ctx = ModelView::DeserializeContext.new(targets: [@model, @model.recursive])
    @view["simple"] = "naughty"

    ex = assert_raises(ViewModel::DeserializationError::Validation) do
      ModelView.deserialize_from_view(@view, deserialize_context: ctx)
    end
    assert_match(/Validation failed: simple was naughty/, ex.message)
  end

  def test_update_read_only
    # Prime our simplistic `resolve_viewmodel` with the desired models to update
    ctx = ModelView::DeserializeContext.new(targets: [@model, @model.recursive])

    @view["readonly"] = "change"
    ex = assert_raises(ViewModel::DeserializationError) do
      ModelView.deserialize_from_view(@view, deserialize_context: ctx)
    end

    assert_match(/Cannot edit read only/, ex.message)
  end

  def test_update_write_once
    # Prime our simplistic `resolve_viewmodel` with the desired models to update
    ctx = ModelView::DeserializeContext.new(targets: [@model, @model.recursive])

    @view["writeonce"] = "change"
    ex = assert_raises(ViewModel::DeserializationError) do
      ModelView.deserialize_from_view(@view, deserialize_context: ctx)
    end

    assert_match(/Cannot edit read only/, ex.message)
  end

  def test_serialize_view
    h = ModelView.new(@model).to_hash(serialize_context: ModelView::SerializeContext.new(include: [:optional, { recursive: :optional }]))
    assert_equal(@view, h)

    @view["recursive"].delete("optional")
    h = ModelView.new(@model).to_hash(serialize_context: ModelView::SerializeContext.new(include: [:optional]))
    assert_equal(@view, h)

    @view.delete("optional")
    h = ModelView.new(@model).to_hash
    assert_equal(@view, h)
  end

  def test_serialize_with_prune
    ['simple',     'optional'].each { |k| @view.delete(k) }
    ['overridden', 'optional'].each { |k| @view["recursive"].delete(k) }

    h = ModelView.new(@model).to_hash(serialize_context: ModelView::SerializeContext.new(prune: [:simple, { recursive: :overridden }]))
    assert_equal(@view, h)
  end

  def test_edit_check_no_changes
    ref            = ViewModel::Reference.new(ModelView, nil)
    access_control = TestAccessControl.new(true, true, true)

    context = ModelView::DeserializeContext.new(
      targets:        [@model, @model.recursive],
      access_control: access_control)

    ModelView.deserialize_from_view(@view, deserialize_context: context)

    assert_empty(access_control.all_valid_edit_changes(ref))
  end

  def test_edit_check # shotgun test of various concerns
    ref            = ViewModel::Reference.new(ModelView, nil)
    access_control = TestAccessControl.new(true, true, true)

    @model.recursive    = nil

    @view["simple"]     = "outer simple changed"
    @view["overridden"] = @view["overridden"] + 42

    context = ModelView::DeserializeContext.new(
      targets:        [@model],
      access_control: access_control)

    ModelView.deserialize_from_view(@view, deserialize_context: context)

    all_changes = access_control.all_valid_edit_changes(ref)
    assert_equal(2, all_changes.length)

    ((inner_changes,), (outer_changes,)) = all_changes.partition { |c| c.new? }

    assert_equal(false, outer_changes.new?)
    assert_equal(false, outer_changes.deleted?)
    assert_equal(%w(simple overridden recursive),
                 outer_changes.changed_attributes)
    assert_empty(outer_changes.changed_associations)

    assert_equal(true, inner_changes.new?)
    assert_equal(false, inner_changes.deleted?)
    assert_equal(%w(simple),
                 inner_changes.changed_attributes)
    assert_empty(inner_changes.changed_associations)
  end

  def test_edit_check_on_create_empty
    access_control = TestAccessControl.new(true, true, true)
    context        = ModelView::DeserializeContext.new(access_control: access_control)

    ModelView.deserialize_from_view(@minimal_view, deserialize_context: context)

    assert_equal([ViewModel::Reference.new(ModelView, nil)],
                 access_control.valid_edit_refs)
  end
end
