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

    def deserialize_overridden(value, deserialize_context:)
      model.overridden = value.try { |v| Integer(v) / 2 }
    end

    class DeserializeContext < ViewModel::DeserializeContext
      attr_reader :targets

      def initialize(targets: [], **rest)
        super(**rest)
        @targets = targets
      end
    end

    def self.deserialize_context_class
      DeserializeContext
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

    @view = {
      '$type'      => "Model",
      '$version'   => 1,
      "simple"     => "simple",
      "overridden" => 4,
      "optional"   => "optional",
      "readonly"   => "readonly",
      "writeonce"  => "writeonce",
      "recursive"  => {
        '$type'      => "Model",
        '$version'   => 1,
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
end
