# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/unit'
require 'minitest/hooks'

require_relative '../../helpers/match_enumerator.rb'
require_relative '../../helpers/arvm_test_utilities.rb'
require_relative '../../helpers/arvm_test_models.rb'
require_relative '../../helpers/viewmodel_spec_helpers.rb'

require 'view_model'
require 'view_model/record'

class ViewModel::TraversalContextTest < ActiveSupport::TestCase
  include ARVMTestUtilities
  extend Minitest::Spec::DSL

  # Use a on-entry callback to ensure that views are visited with the expected
  # local TraversalContext in various flows
  ContextDetail = Value.new(:parent_ref, :parent_association, :root)

  class ContextRecorder
    include ViewModel::Callbacks
    attr_reader :details

    # Views are identified by their ref (type/id): this means that for the
    # purposes of these tests, new models must all have an id specified.
    def initialize
      @details = {}
    end

    # record information after_visit: allows id of new models to be established
    after_visit do
      ref = view.to_reference
      raise RuntimeError.new('Visited twice') if details.has_key?(ref)

      details[ref] = ContextDetail.new(
        context.parent_viewmodel&.to_reference,
        context.parent_association,
        context.root?)
    end
  end

  let(:vm) { create_viewmodel! }

  let(:context_recorder) { ContextRecorder.new }

  # Set up serialization and deserialization helpers to use the recording callback
  def vm_serialize_context(viewmodel_class, **args)
    viewmodel_class.new_serialize_context(callbacks: [context_recorder], **args)
  end

  def vm_deserialize_context(viewmodel_class, **args)
    viewmodel_class.new_deserialize_context(callbacks: [context_recorder], **args)
  end

  def serialize(view, serialize_context: vm_serialize_context(view.class))
    super(view, serialize_context: serialize_context)
  end

  def serialize_with_references(view, serialize_context: vm_serialize_context(view.class))
    super(view, serialize_context: serialize_context)
  end

  # use `alter_by_view` to test deserialization: only override the deserialize_context
  def alter_by_view!(vm_class, model,
                     deserialize_context: vm_deserialize_context(vm_class),
                     **args,
                     &block)
    super(vm_class, model, deserialize_context: deserialize_context, **args, &block)
  end

  module TraversalBehaviour
    extend ActiveSupport::Concern
    include Minitest::Hooks

    def assert_traversal_matches(expected_details, recorded_details)
      value(recorded_details.keys).must_contain_exactly(expected_details.keys)

      recorded_details.each do |model_id, recorded_detail|
        value(recorded_detail).must_equal(expected_details[model_id])
      end
    end

    # Helpers to manipulate alter_by_view view hashes. Assumes that the test
    # models have no more than one shared association, and if present it is the
    # one under test.
    def clear_subject_association(view, refs)
      refs.clear if subject_association.referenced?
      view[subject_association_name] = subject_association.collection? ? [] : nil
    end

    def set_subject_association(view, refs, value)
      if subject_association.referenced?
        refs.clear
        value = convert_to_refs(refs, value)
      end
      view[subject_association_name] = value
    end

    def add_to_subject_association(view, refs, value)
      if subject_association.referenced?
        value = convert_to_refs(refs, value)
      end
      view[subject_association_name] << value
    end

    def remove_from_subject_association(view, refs)
      view[subject_association_name].reject! do |child|
        if subject_association.referenced?
          ref = child[ViewModel::REFERENCE_ATTRIBUTE]
          child = refs[ref]
        end
        match = yield(child)
        if match && subject_association.referenced?
          refs.delete(ref)
        end
        match
      end
    end

    def convert_to_refs(refs, value)
      i = 0
      ViewModel::Utils.map_one_or_many(value) do |v|
        ref = "_child_ref_#{i += 1}"
        refs[ref] = v
        { ViewModel::REFERENCE_ATTRIBUTE => ref }
      end
    end
  end

  module BehavesLikeSerialization
    extend ActiveSupport::Concern
    include TraversalBehaviour
    # requires :expected_parent_details, :expected_children_details

    def self.included(base)
      base.instance_eval do
        it 'traverses as expected while serializing' do
          serialize_with_references(vm)
          expected = expected_parent_details.merge(expected_children_details)
          assert_traversal_matches(expected, context_recorder.details)
        end
      end
    end
  end

  module BehavesLikeDeserialization
    extend ActiveSupport::Concern
    include TraversalBehaviour
    # requires
    # :expected_parent_details, :expected_children_details
    # :new_child_hash, :new_child_expected_details

    def self.included(base)
      base.instance_eval do
        it 'traverses as expected while deserializing' do
          alter_by_view!(viewmodel_class, vm.model) {}
          expected = expected_parent_details.merge(expected_children_details)
          assert_traversal_matches(expected, context_recorder.details)
        end

        it 'traverses as expected while clearing child(ren)' do
          alter_by_view!(viewmodel_class, vm.model) do |view, refs|
            clear_subject_association(view, refs)
          end

          expected = expected_parent_details
          expected = expected.merge(expected_children_details) unless subject_association.referenced?
          assert_traversal_matches(expected, context_recorder.details)
        end

        it 'traverses as expected while replacing child(ren)' do
          replacement = subject_association.collection? ? [new_child_hash] : new_child_hash

          alter_by_view!(viewmodel_class, vm.model) do |view, refs|
            set_subject_association(view, refs, replacement)
          end

          expected = expected_parent_details
          expected = expected.merge(expected_children_details) unless subject_association.referenced?
          expected = expected.merge(new_child_expected_details)
          assert_traversal_matches(expected, context_recorder.details)
        end

        it 'traverses as expected in replace_associated' do
          ctx = vm_deserialize_context(viewmodel_class)
          replacement = subject_association.collection? ? [new_child_hash] : new_child_hash
          vm.replace_associated(subject_association_name, replacement, deserialize_context: ctx)

          expected = expected_parent_details
          expected = expected.merge(expected_children_details) unless subject_association.referenced?
          expected = expected.merge(new_child_expected_details)
          assert_traversal_matches(expected, context_recorder.details)
        end
      end
    end
  end

  module BehavesLikeCollectionDeserialization
    extend ActiveSupport::Concern
    include TraversalBehaviour

    # requires :removed_child
    def self.included(base)
      base.instance_eval do
        it 'traverses as expected when adding to children' do
          alter_by_view!(viewmodel_class, vm.model) do |view, refs|
            add_to_subject_association(view, refs, new_child_hash)
          end

          expected = expected_parent_details
                       .merge(expected_children_details)
                       .merge(new_child_expected_details)
          assert_traversal_matches(expected, context_recorder.details)
        end

        it 'traverses as expected when removing from children' do
          alter_by_view!(viewmodel_class, vm.model) do |view, refs|
            remove_from_subject_association(view, refs) do |child|
              child['id'] == removed_child.id
            end
          end

          expected = expected_parent_details.merge(expected_children_details)
          expected = expected.except(removed_child.to_reference) if subject_association.referenced?
          assert_traversal_matches(expected, context_recorder.details)
        end

        it 'traverses as expected in append_associated' do
          ctx = vm_deserialize_context(viewmodel_class)
          vm.append_associated(subject_association_name, [new_child_hash], deserialize_context: ctx)

          expected = expected_parent_details.merge(new_child_expected_details)
          assert_traversal_matches(expected, context_recorder.details)
        end

        it 'traverses as expected in delete_associated' do
          ctx = vm_deserialize_context(viewmodel_class)
          vm.delete_associated(subject_association_name, removed_child.id, deserialize_context: ctx)

          expected = expected_parent_details
          expected = expected.merge(removed_child_expected_details) unless subject_association.referenced?
          assert_traversal_matches(expected, context_recorder.details)
        end
      end
    end
  end

  module BehavesLikeVisitor
    def self.included(base)
      base.instance_eval do
        it 'traverses as expected while visiting' do
          ViewModel::ActiveRecord::Visitor.new.visit(vm, context: vm_serialize_context(viewmodel_class))
          expected = expected_parent_details.merge(expected_children_details)
          assert_traversal_matches(expected, context_recorder.details)
        end
      end
    end
  end

  # For each association type we want to make sure the traversal environment is
  # as expected in every method of traversal.

  let(:root_detail) { ContextDetail.new(nil, nil, true) }
  let(:child_detail) do
    if subject_association.referenced?
      root_detail
    else
      ContextDetail.new(vm.to_reference, subject_association_name, false)
    end
  end

  let(:expected_parent_details) do
    { vm.to_reference => root_detail }
  end

  let(:expected_children_details) do
    children = {}
    Array.wrap(vm.send(subject_association_name)).each do |child_vm|
      children[child_vm.to_reference] = child_detail
    end
    children
  end

  before(:each) { expected_children_details }

  let(:new_model) do
    associated =
      if subject_association.collection?
        [child_model_class.new(name: 'b'), child_model_class.new(name: 'c')]
      else
        child_model_class.new(name: 'b')
      end

    model_class.new(name: 'a', subject_association_name => associated)
  end

  let(:new_child_id) { 9999 }
  let(:new_child_ref) { ViewModel::Reference.new(child_viewmodel_class, new_child_id) }
  let(:new_child_hash) do
    {
      '_type' => child_viewmodel_class.view_name,
      'id'    => new_child_id,
      '_new'  => true,
      'name'  => 'z',
    }
  end

  let(:new_child_expected_details) do
    { new_child_ref => child_detail }
  end

  let(:removed_child) do
    Array.wrap(vm.send(subject_association_name)).first
  end

  let(:removed_child_expected_details) do
    { removed_child.to_reference => child_detail }
  end

  describe 'with parent and belongs to child' do
    include ViewModelSpecHelpers::ParentAndBelongsToChild

    include BehavesLikeSerialization
    include BehavesLikeDeserialization
    include BehavesLikeVisitor
  end

  describe 'with parent and has_one child' do
    include ViewModelSpecHelpers::ParentAndBelongsToChild

    include BehavesLikeSerialization
    include BehavesLikeDeserialization
    include BehavesLikeVisitor
  end

  describe 'with parent and has_many children' do
    include ViewModelSpecHelpers::ParentAndHasManyChildren

    include BehavesLikeSerialization
    include BehavesLikeDeserialization
    include BehavesLikeCollectionDeserialization
    include BehavesLikeVisitor
  end

  describe 'with parent and shared child' do
    include ViewModelSpecHelpers::ParentAndSharedBelongsToChild

    include BehavesLikeSerialization
    include BehavesLikeDeserialization
    include BehavesLikeVisitor
  end

  describe 'with parent and has-many-through children' do
    include ViewModelSpecHelpers::ParentAndHasManyThroughChildren
    let(:new_model) do
      model_class.new(name: 'a',
                      model_children: [
                        join_model_class.new(child: child_model_class.new(name: 'b')),
                        join_model_class.new(child: child_model_class.new(name: 'c')),
                      ])
    end

    include BehavesLikeSerialization
    include BehavesLikeDeserialization
    include BehavesLikeCollectionDeserialization
    include BehavesLikeVisitor
  end
end
