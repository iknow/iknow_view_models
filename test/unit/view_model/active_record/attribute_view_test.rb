require_relative "../../../helpers/arvm_test_utilities.rb"
require_relative "../../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "view_model/active_record"

class ViewModel::ActiveRecord::AttributeViewTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  class ComplexAttributeView < ViewModel
    attribute :array

    def serialize_view(json, serialize_context:)
      json.a array[0]
      json.b array[1]
    end

    def self.deserialize_from_view(hash_data, deserialize_context:)
      array = [hash_data["a"], hash_data["b"]]
      self.new(array)
    end
  end

  def before_all
    super

    build_viewmodel(:Pair) do
      define_schema do |t|
        t.column :pair, "integer[]"
      end

      define_model do
      end

      define_viewmodel do
        attribute :pair, using: ComplexAttributeView
        include TrivialAccessControl
      end
    end
  end

  def setup
    super
    @pair = Pair.create!(pair: [1,2])
  end

  def test_serialize_view
    view, _refs = serialize_with_references(PairView.new(@pair))

    assert_equal({ "_type" => "Pair",
                   "id"    => @pair.id,
                   "pair"  => { "a" => 1, "b" => 2 }},
                 view)
  end

  def test_create
    view = { "_type" => "Pair", "pair" => { "a" => 3, "b" => 4 } }
    pv = PairView.deserialize_from_view(view)
    assert_equal([3,4], pv.model.pair)
  end
end
