require "minitest/autorun"
require "minitest/unit"
require "minitest/hooks"

require_relative "../../../helpers/arvm_test_models.rb"
require_relative "../../../helpers/viewmodel_spec_helpers.rb"

# MiniTest::Spec.register_spec_type(/./, Minitest::HooksSpec)

require "view_model"
require "view_model/active_record"

class ViewModel::ActiveRecord
  class ClonerTest < ActiveSupport::TestCase
    using ViewModel::Utils::Collections
    extend Minitest::Spec::DSL

    let(:viewmodel) { create_viewmodel! }
    let(:model)     { viewmodel.model }

    describe "with single model" do
      include ViewModelSpecHelpers::Single

      def model_attributes
        super.merge(schema: ->(t) { t.string :nonview })
      end

      def new_model
        model_class.new(name: "a", nonview: "b")
      end

      it "persists the test setup" do
        assert(viewmodel.model.persisted?)
        refute(viewmodel.model.new_record?)
      end

      it "can clone the model" do
        clone_model = Cloner.new.clone(viewmodel)
        assert(clone_model.new_record?)
        assert_nil(clone_model.id)
        assert_equal(model.name, clone_model.name)
        assert_equal(model.nonview, clone_model.nonview)
        clone_model.save!
        refute_equal(model, clone_model)
      end

      class IgnoreParentCloner < Cloner
        def visit_model_view(node, model)
          ignore!
        end
      end

      it "can ignore a model" do
        clone_model = IgnoreParentCloner.new.clone(viewmodel)
        assert_nil(clone_model)
      end

      class IgnoreAllCloner < Cloner
        def pre_visit(node, model)
          ignore!
        end
      end

      it "can ignore a model in pre-visit" do
        clone_model = IgnoreAllCloner.new.clone(viewmodel)
        assert_nil(clone_model)
      end

      class AlterAttributeCloner < Cloner
        def visit_model_view(node, model)
          model.name = "changed"
        end
      end

      it "can alter a model attribute" do
        clone_model = AlterAttributeCloner.new.clone(viewmodel)
        assert(clone_model.new_record?)
        assert_nil(clone_model.id)
        assert_equal("changed", clone_model.name)
        refute_equal("changed", model.name)
        assert_equal(model.nonview, clone_model.nonview)
        clone_model.save!
        refute_equal(model, clone_model)
      end

      class PostAlterAttributeCloner < Cloner
        def end_visit_model_view(node, model)
          model.name = "changed"
        end
      end

      it "can alter a model attribute post-visit" do
        clone_model = PostAlterAttributeCloner.new.clone(viewmodel)
        assert(clone_model.new_record?)
        assert_nil(clone_model.id)
        assert_equal("changed", clone_model.name)
        refute_equal("changed", model.name)
        assert_equal(model.nonview, clone_model.nonview)
        clone_model.save!
        refute_equal(model, clone_model)
      end
    end

    describe "with a child" do
      def new_child_model
        child_model_class.new(name: "b")
      end

      def new_model
        model_class.new(name: "a", child: new_child_model)
      end

      module BehavesLikeConstructingAChild
        extend ActiveSupport::Concern
        included do
          it "persists the test setup" do
            assert(viewmodel.model.persisted?)
            refute(viewmodel.model.new_record?)
            assert(viewmodel.model.child.persisted?)
            refute(viewmodel.model.child.new_record?)
          end
        end
      end

      class IgnoreChildAssociationCloner < Cloner
        def visit_model_view(node, model)
          ignore_association!(:child)
        end
      end

      module BehavesLikeCloningAChild
        extend ActiveSupport::Concern
        included do
          it "can clone the model and child" do
            clone_model = Cloner.new.clone(viewmodel)

            assert(clone_model.new_record?)
            assert_nil(clone_model.id)
            assert_equal(model.name, clone_model.name)

            clone_child = clone_model.child
            assert(clone_child.new_record?)
            assert_nil(clone_child.id)
            assert_equal(clone_child.name, model.child.name)

            clone_model.save!
            refute_equal(model, clone_model)
            refute_equal(model.child, clone_model.child)
          end

          it "can ignore the child association" do
            clone_model = IgnoreChildAssociationCloner.new.clone(viewmodel)

            assert(clone_model.new_record?)
            assert_nil(clone_model.id)
            assert_equal(model.name, clone_model.name)

            assert_nil(clone_model.child)
          end
        end
      end

      describe "as belongs_to" do
        include ViewModelSpecHelpers::ParentAndBelongsToChild
        include BehavesLikeConstructingAChild
        include BehavesLikeCloningAChild
      end

      describe "as has_one" do
        include ViewModelSpecHelpers::ParentAndHasOneChild
        include BehavesLikeConstructingAChild
        include BehavesLikeCloningAChild
      end

      describe "as belongs_to shared child" do
        include ViewModelSpecHelpers::ParentAndSharedBelongsToChild
        include BehavesLikeConstructingAChild
        it "can clone the model but not the child" do
            clone_model = Cloner.new.clone(viewmodel)

            assert(clone_model.new_record?)
            assert_nil(clone_model.id)
            assert_equal(model.name, clone_model.name)

            clone_child = clone_model.child
            refute(clone_child.new_record?)
            assert_equal(model.child, clone_child)

            clone_model.save!
            refute_equal(model, clone_model)
            assert_equal(model.child, clone_model.child)
          end
      end
    end

    describe "with has_many children" do
      include ViewModelSpecHelpers::ParentAndHasManyChildren
      def new_child_models
        ["b", "c"].map { |n| child_model_class.new(name: n) }
      end

      def new_model
        model_class.new(name: "a", children: new_child_models)
      end

      it "persists the test setup" do
        assert(viewmodel.model.persisted?)
        refute(viewmodel.model.new_record?)
        assert_equal(2, viewmodel.model.children.size)
        viewmodel.model.children.each do | child|
          assert(child.persisted?)
          refute(child.new_record?)
        end
      end

      it "can clone the model" do
        clone_model = Cloner.new.clone(viewmodel)

        assert(clone_model.new_record?)
        assert_nil(clone_model.id)
        assert_equal(model.name, clone_model.name)

        assert_equal(2, clone_model.children.size)

        clone_model.children.zip(model.children) do |clone_child, child|
          assert(clone_child.new_record?)
          assert_nil(clone_child.id)
          assert_equal(clone_child.name, child.name)
        end

        clone_model.save!
        refute_equal(model, clone_model)
        clone_model.children.zip(model.children) do |clone_child, child|
          refute_equal(clone_child, child)
        end
      end

      class IgnoreFirstChildCloner < Cloner
        def initialize
          @ignored_first = false
        end

        def visit_child_view(node, model)
          unless @ignored_first
            @ignored_first = true
            ignore!
          end
        end
      end

      it "can ignore subset of children" do
        clone_model = IgnoreFirstChildCloner.new.clone(viewmodel)

        assert(clone_model.new_record?)
        assert_nil(clone_model.id)
        assert_equal(model.name, clone_model.name)

        assert_equal(1, clone_model.children.size)
        assert_equal(model.children[1].name, clone_model.children[0].name)
      end
    end

    describe "with has_many_through shared children" do
      include ViewModelSpecHelpers::ParentAndHasManyThroughChildren
      def new_model_children
        ["b", "c"].map.with_index do |n, i|
          join_model_class.new(child: child_model_class.new(name: n), position: i)
        end
      end

      def new_model
        model_class.new( name: "a", model_children: new_model_children)
      end

      it "persists the test setup" do
        assert(viewmodel.model.persisted?)
        refute(viewmodel.model.new_record?)
        assert_equal(2, viewmodel.model.model_children.size)
        viewmodel.model.model_children.each do |model_child|
          assert(model_child.persisted?)
          refute(model_child.new_record?)

          assert(model_child.child.persisted?)
          refute(model_child.child.new_record?)
        end
      end

      it "can clone the model and join model but not the child" do
        clone_model = Cloner.new.clone(viewmodel)

        assert(clone_model.new_record?)
        assert_nil(clone_model.id)
        assert_equal(model.name, clone_model.name)

        assert_equal(2, clone_model.model_children.size)

        clone_model.model_children.zip(model.model_children) do |clone_model_child, model_child|
          assert(clone_model_child.new_record?)
          assert_nil(clone_model_child.id)
          assert_equal(clone_model_child.position, model_child.position)
          assert_equal(clone_model_child.child, model_child.child)
        end

        clone_model.save!
        refute_equal(model, clone_model)
        clone_model.model_children.zip(model.model_children) do |clone_model_child, model_child|
          refute_equal(clone_model_child, model_child)
          assert_equal(clone_model_child.child, model_child.child)
        end
      end
    end
  end
end
