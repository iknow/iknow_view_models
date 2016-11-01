require_relative "../../../helpers/arvm_test_utilities.rb"
require_relative "../../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "view_model/active_record"

class ViewModel::ActiveRecord::AttributeViewTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def before_all
    super

    build_viewmodel(:Thing) do
      define_schema do |t|
        t.integer :a
        t.integer :b
      end

      define_model do
      end

      define_viewmodel do
        attribute :a
        attribute :b, optional: true
      end
    end
  end

  def setup
    super
    @thing = Thing.create!(a: 1, b: 2)

    @skel = { "_type"    => "Thing",
              "_version" => 1,
              "id"       => @thing.id }
  end

  def test_optional_not_serialized
    view, _refs = serialize_with_references(ThingView.new(@thing))

    assert_equal(@skel.merge("a" => 1), view)
  end

  def test_optional_included
    view, _refs = serialize_with_references(ThingView.new(@thing),
                                            serialize_context: ThingView.new_serialize_context(include: :b))

    assert_equal(@skel.merge("a" => 1, "b" => 2), view)
  end

  def test_pruned_not_included
    view, _refs = serialize_with_references(ThingView.new(@thing),
                                            serialize_context: ThingView.new_serialize_context(include: :b, prune: :a))

    assert_equal(@skel.merge("b" => 2), view)
  end
end
