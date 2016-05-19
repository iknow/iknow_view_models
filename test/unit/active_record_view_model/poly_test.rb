require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

class ActiveRecordViewModel::PolyTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  module WithPoly
    def before_all
      super

      build_viewmodel(:PolyOne) do
        define_schema do |t|
          t.integer :number
        end

        define_model do
          has_one :parent, as: :poly
        end

        define_viewmodel do
          attributes :number
          include TrivialAccessControl
        end
      end

      build_viewmodel(:PolyTwo) do
        define_schema do |t|
          t.string :text
        end

        define_model do
          has_one :parent, as: :poly
        end

        define_viewmodel do
          attributes :text
          include TrivialAccessControl
        end
      end
    end
  end

  module WithParent
    def before_all
      super

      build_viewmodel(:Parent) do
        define_schema do |t|
          t.string :name
          t.string :poly_type
          t.integer :poly_id
        end

        define_model do
          belongs_to :poly, polymorphic: true, dependent: :destroy, inverse_of: :parent
        end

        define_viewmodel do
          attributes   :name
          association :poly, viewmodels: [Views::PolyOne, Views::PolyTwo]
          include TrivialAccessControl
        end
      end
    end
  end

  include WithPoly
  include WithParent

  def setup
    super

    @parent1 = Parent.create(name: "p1",
                             poly: PolyOne.new(number: 1))

    @parent2 = Parent.create(name: "p2")

    enable_logging!
  end

  def test_loading_batching
    Parent.create(name: "with PolyOne", poly: PolyOne.new)
    Parent.create(name: "with PolyTwo", poly: PolyTwo.new)

    log_queries do
      serialize(Views::Parent.load)
    end
    assert_equal(['Parent Load', 'PolyOne Load', 'PolyTwo Load'],
                 logged_load_queries.sort)
  end

  def test_create_from_view
    view = {
      "_type"    => "Parent",
      "name"     => "p",
      "poly"     => { "_type" => "PolyTwo", "text" => "pol" }
    }

    pv = Views::Parent.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal("p", p.name)

    assert(p.poly.present?)
    assert(p.poly.is_a?(PolyTwo))
    assert_equal("pol", p.poly.text)
  end


  def test_serialize_view
    view, _refs = serialize_with_references(Views::Parent.new(@parent1))

    assert_equal({ "_type" => "Parent",
                   "id" => @parent1.id,
                   "name" => @parent1.name,
                   "poly" => { "_type" => @parent1.poly_type,
                               "id" => @parent1.poly.id,
                               "number" => @parent1.poly.number }
                 },
                 view)
  end

  def test_change_polymorphic_type
    old_poly = @parent1.poly

    alter_by_view!(Views::Parent, @parent1) do |view, refs|
      view['poly'] = { '_type' => 'PolyTwo', 'text' => 'hi' }
    end

    assert_instance_of(PolyTwo, @parent1.poly)
    assert_equal(false, PolyOne.exists?(old_poly.id))
  end

end
