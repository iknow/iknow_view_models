require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

class ActiveRecordViewModel::PolyTest < ActiveSupport::TestCase
  include ARVMTestUtilities

  def self.build_poly(arvm_test_case)
    arvm_test_case.build_viewmodel(:PolyOne) do
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

    arvm_test_case.build_viewmodel(:PolyTwo) do
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

  def self.build_parent(arvm_test_case)
    arvm_test_case.build_viewmodel(:Parent) do
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
        association :poly, viewmodels: [PolyOneView, PolyTwoView]
        include TrivialAccessControl
      end
    end
  end

  def before_all
    super

    self.class.build_poly(self)
    self.class.build_parent(self)
  end

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
      serialize(ParentView.load)
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

    pv = ParentView.deserialize_from_view(view)
    p = pv.model

    assert(!p.changed?)
    assert(!p.new_record?)

    assert_equal("p", p.name)

    assert(p.poly.present?)
    assert(p.poly.is_a?(PolyTwo))
    assert_equal("pol", p.poly.text)
  end


  def test_serialize_view
    view, _refs = serialize_with_references(ParentView.new(@parent1))

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

    alter_by_view!(ParentView, @parent1) do |view, refs|
      view['poly'] = { '_type' => 'PolyTwo', 'text' => 'hi' }
    end

    assert_instance_of(PolyTwo, @parent1.poly)
    assert_equal(false, PolyOne.exists?(old_poly.id))
  end

  class RenameTest < ActiveSupport::TestCase
    include ARVMTestUtilities

    def before_all
      super

      ActiveRecordViewModel::PolyTest.build_poly(self)

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
          attributes :name
          association :poly, viewmodels: [PolyOneView, PolyTwoView], as: :something_else
          include TrivialAccessControl
        end
      end
    end

    def setup
      super

      @parent = Parent.create(poly: PolyOne.create(number: 42))

      enable_logging!
    end

    def test_dependencies
      root_updates, ref_updates = ActiveRecordViewModel::UpdateData.parse_hashes([{ '_type' => 'Parent', 'something_else' => nil }])
      assert_equal({ 'poly' => {} }, root_updates.first.association_dependencies(ref_updates))
      assert_equal({ 'something_else' => {} }, root_updates.first.updated_associations(ref_updates))
    end


    def test_renamed_roundtrip
      alter_by_view!(ParentView, @parent) do |view, refs|
        assert_equal({ 'id'     => @parent.id,
                       '_type'  => 'PolyOne',
                       'number' => 42 },
                     view['something_else'])
        view['something_else'] = {'_type' => 'PolyTwo', 'text' => 'hi'}
      end

      assert_equal('hi', @parent.poly.text)
    end
  end

end
