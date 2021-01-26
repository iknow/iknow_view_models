# frozen_string_literal: true

require_relative '../../../helpers/arvm_test_utilities'
require_relative '../../../helpers/arvm_test_models'
require_relative '../../../helpers/viewmodel_spec_helpers'

require 'minitest/autorun'

require 'view_model/active_record'

class ViewModel::ActiveRecord::Migration < ActiveSupport::TestCase
  include ARVMTestUtilities
  extend Minitest::Spec::DSL

  def new_model
    model_class.new(name: 'm1', child: child_model_class.new(name: 'c1'))
  end

  let(:viewmodel) { create_viewmodel! }

  let(:migration_versions) { { viewmodel_class => 2, child_viewmodel_class => 2 } }

  let(:down_migrator) { ViewModel::DownMigrator.new(migration_versions) }
  let(:up_migrator) { ViewModel::UpMigrator.new(migration_versions) }

  def migrate!
    migrator.migrate!(subject)
  end

  let(:current_serialization) do
    ctx = viewmodel_class.new_serialize_context
    view = ViewModel.serialize_to_hash(viewmodel, serialize_context: ctx)
    refs = ctx.serialize_references_to_hash
    { 'data' => view, 'references' => refs }
  end

  let(:v2_serialization_data) do
    {
        ViewModel::TYPE_ATTRIBUTE => viewmodel_class.view_name,
        ViewModel::VERSION_ATTRIBUTE => 2,
        ViewModel::ID_ATTRIBUTE => viewmodel.id,
        'name' => viewmodel.name,
        'old_field' => 1,
        'child' => {
          ViewModel::TYPE_ATTRIBUTE => child_viewmodel_class.view_name,
          ViewModel::VERSION_ATTRIBUTE => 2,
          ViewModel::ID_ATTRIBUTE => viewmodel.child.id,
          'name' => viewmodel.child.name,
          'former_field' => 'former_value',
        },
    }
  end

  let(:v2_serialization_references) { {} }

  let(:v2_serialization) do
    {
      'data' => v2_serialization_data,
      'references' => v2_serialization_references,
    }
  end

  describe 'with defined migrations' do
    include ViewModelSpecHelpers::ParentAndBelongsToChildWithMigration

    describe 'downwards' do
      let(:migrator) { down_migrator }
      let(:subject) { current_serialization.deep_dup }

      let(:expected_result) do
        v2_serialization.deep_merge(
          {
            'data' => {
              ViewModel::MIGRATED_ATTRIBUTE => true,
              'old_field' => -1,
              'child' => {
                ViewModel::MIGRATED_ATTRIBUTE => true,
                'former_field' => 'reconstructed',
              },
            },
          })
      end

      it 'migrates' do
        migrate!

        assert_equal(expected_result, subject)
      end

      describe 'to an unreachable version' do
        let(:migration_versions) { { viewmodel_class => 2, child_viewmodel_class => 1 } }

        it 'raises' do
          assert_raises(ViewModel::Migration::NoPathError) do
            migrate!
          end
        end
      end
    end

    describe 'upwards' do
      let(:migrator) { up_migrator }
      let(:subject_data) { v2_serialization_data.deep_dup }
      let(:subject_references) { v2_serialization_references.deep_dup }
      let(:subject) { { 'data' => subject_data, 'references' => subject_references } }

      let(:expected_result) do
        current_serialization.deep_merge(
          {
            'data' => {
              ViewModel::MIGRATED_ATTRIBUTE => true,
              'new_field' => 3,
              'child' => {
                ViewModel::MIGRATED_ATTRIBUTE => true,
              },
            },
          }
        )
      end

      it 'migrates' do
        migrate!

        assert_equal(expected_result, subject)
      end

      describe 'with version unspecified' do
        let(:subject_data) do
          v2_serialization_data.except(ViewModel::VERSION_ATTRIBUTE)
        end

        it 'treats it as the requested version' do
          migrate!
          assert_equal(expected_result, subject)
        end
      end

      describe 'with a version not in the specification' do
        let(:subject_data) do
          v2_serialization_data
            .except('old_field')
            .deep_merge(ViewModel::VERSION_ATTRIBUTE => 3, 'mid_field' => 1)
        end

        it 'rejects it' do
          assert_raises(ViewModel::Migration::UnspecifiedVersionError) do
            migrate!
          end
        end
      end

      describe 'from an unreachable version' do
        let(:migration_versions) { { viewmodel_class => 2, child_viewmodel_class => 1 } }

        let(:subject_data) do
          v2_serialization_data.deep_merge(
            'child' => { ViewModel::VERSION_ATTRIBUTE => 1 },
          )
        end

        it 'raises' do
          assert_raises(ViewModel::Migration::NoPathError) do
            migrate!
          end
        end
      end

      describe 'in an undefined direction' do
        let(:migration_versions) { { viewmodel_class => 1, child_viewmodel_class => 2 } }

        let(:subject_data) do
          v2_serialization_data.except('old_field').merge(ViewModel::VERSION_ATTRIBUTE => 1)
        end

        it 'raises' do
          assert_raises(ViewModel::Migration::OneWayError) do
            migrate!
          end
        end
      end
    end
  end

  describe 'garbage collection' do
    include ViewModelSpecHelpers::ParentAndSharedBelongsToChild

    # current (v2) features the shared child, v1 did not
    def model_attributes
      super.merge(
        viewmodel: ->(_v) {
          self.schema_version = 2
          migrates from: 1, to: 2 do
            down do |view, refs|
              view.delete('child')
            end
          end
        })
    end

    # current (v2) refers to another child, v1 did not
    def child_attributes
      super.merge(
        schema: ->(t) { t.references :child, foreign_key: true },
        model: ->(m) {
          belongs_to :child, inverse_of: :parent, dependent: :destroy
          has_one :parent, inverse_of: :child, class_name: self.name
        },
        viewmodel: ->(_v) {
          self.schema_version = 2
          association :child
          migrates from: 1, to: 2 do
            down do |view, refs|
              view.delete('child')
            end
          end
        })
    end

    def new_model
      model_class.new(name: 'm1',
                      child: child_model_class.new(
                        name: 'c1',
                        child: child_model_class.new(
                          name: 'c2')))
    end


    let(:migrator) { down_migrator }
    let(:migration_versions) { { viewmodel_class => 1, child_viewmodel_class => 1 } }

    let(:subject) { current_serialization.deep_dup }

    let(:expected_result) do
      {
        'data' => {
          ViewModel::TYPE_ATTRIBUTE => viewmodel_class.view_name,
          ViewModel::VERSION_ATTRIBUTE => 1,
          ViewModel::ID_ATTRIBUTE => viewmodel.id,
          ViewModel::MIGRATED_ATTRIBUTE => true,
          'name' => viewmodel.name,
        },
        'references' => {},
      }
    end

    it 'migrates' do
      migrate!

      assert_equal(expected_result, subject)
    end
  end

  describe 'without migrations' do
    describe 'to an unreachable version' do
      include ViewModelSpecHelpers::ParentAndBelongsToChild

      def model_attributes
        super.merge(viewmodel: ->(_v) {
                      self.schema_version = 4
                      # Define an unreachable migration to ensure that the view
                      # attempts to realize paths.
                      migrates from: 1, to: 2 do
                      end
                    })
      end

      def child_attributes
        super.merge(viewmodel: ->(_v) { self.schema_version = 3 })
      end

      let(:migrator) { down_migrator }
      let(:subject) { current_serialization.deep_dup }

      it 'raises no path error' do
        assert_raises(ViewModel::Migration::NoPathError) do
          migrate!
        end
      end
    end
  end
end
