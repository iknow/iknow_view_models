require_relative "../../helpers/arvm_test_utilities.rb"
require_relative "../../helpers/arvm_test_models.rb"

require "minitest/autorun"

require "active_record_view_model"

module ActiveRecordViewModel::PolyTest
  ## Polymorphic pointer to parent in child (child may belong to different type parents)
  class PolyParentPointerTest < ActiveSupport::TestCase
    include ARVMTestUtilities
    def before_all
      super
      build_viewmodel(:Child) do
        define_schema do |t|
          t.string  :text
          t.string  :poly_type
          t.integer :poly_id
        end
        define_model do
          belongs_to :poly, polymorphic: true
        end
        define_viewmodel do
          attributes :text
          include TrivialAccessControl
        end
      end

      build_viewmodel(:PolyParentOne) do
        define_schema do |t|
          t.string :text
        end
        define_model do
          has_one :grandparent, inverse_of: :poly_parent_one
          has_one :child, as: :poly, dependent: :destroy, inverse_of: :poly
        end
        define_viewmodel do
          attributes :text
          association :child
          include TrivialAccessControl
        end
      end

      build_viewmodel(:PolyParentTwo) do
        define_schema do |t|
          t.integer :num
        end
        define_model do
          has_one :grandparent, inverse_of: :poly_parent_two
          has_many :children, as: :poly, dependent: :destroy, inverse_of: :poly
        end
        define_viewmodel do
          attributes :num
          association :children
          include TrivialAccessControl
        end
      end

      build_viewmodel(:Grandparent) do
        define_schema do |t|
          t.integer :poly_parent_one_id
          t.integer :poly_parent_two_id
        end
        define_model do
          belongs_to :poly_parent_one, dependent: :destroy, inverse_of: :grandparent
          belongs_to :poly_parent_two, dependent: :destroy, inverse_of: :grandparent
        end
        define_viewmodel do
          associations :poly_parent_one, :poly_parent_two
        end
      end
    end

    def setup
      super
      @parent1 = PolyParentOne.create(text: "p1", child: Child.new(text: "c1"))
      @parent2 = PolyParentTwo.create(num: 2, children: [Child.new(text: "c2"), Child.new(text: "c3")])
      @grandparent = Grandparent.create(poly_parent_one: @parent1, poly_parent_two: @parent2)
      enable_logging!
    end

    def test_create_has_one_from_view
      p1_view = {
        "_type" => "PolyParentOne",
        "text"  => "p",
        "child" => { "_type" => "Child", "text" => "c" }
      }
      p1v = PolyParentOneView.deserialize_from_view(p1_view)
      p1 = p1v.model

      assert(p1.present?)
      assert(p1.child.present?)
      assert_equal(p1, p1.child.poly)
    end

    def test_create_has_many_from_view
      p2_view = {
        "_type" => "PolyParentTwo",
        "num"   => "2",
        "children" => [{ "_type" => "Child", "text" => "c1" }, { "_type" => "Child", "text" => "c2" }]
      }
      p2v = PolyParentTwoView.deserialize_from_view(p2_view)
      p2 = p2v.model

      assert(p2.present?)
      assert(p2.children.count == 2)
      p2.children.each do |c|
        assert_equal(p2, c.poly)
      end
    end

    def test_move
      # test that I can move a child from one type to another and the parent pointer/type is correctly updated.
      alter_by_view!(GrandparentView, @grandparent) do |view, refs|
        c1 = view["poly_parent_one"]["child"]
        c2 = view["poly_parent_two"]["children"].pop
        view["poly_parent_one"]["child"] = c2
        view["poly_parent_two"]["children"].push(c1)
      end
      @grandparent.reload
      assert_equal("c3", @grandparent.poly_parent_one.child.text)
      assert_equal(["c1","c2"], @grandparent.poly_parent_two.children.map(&:text).sort)
    end
  end

  ## Polymorphic pointer to child in parent (multiple types of child)
  class PolyChildPointerTest < ActiveSupport::TestCase
    include ARVMTestUtilities
    def self.build_poly_children(arvm_test_case)
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
      self.class.build_poly_children(self)
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

        ActiveRecordViewModel::PolyTest::PolyChildPointerTest.build_poly_children(self)

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
end
