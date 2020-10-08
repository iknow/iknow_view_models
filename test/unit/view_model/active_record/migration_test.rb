require_relative '../../../helpers/arvm_test_utilities.rb'
require_relative '../../../helpers/arvm_test_models.rb'
require_relative '../../../helpers/viewmodel_spec_helpers.rb'

require 'minitest/autorun'

require 'view_model/active_record'

class ViewModel::ActiveRecord::Migration < ActiveSupport::TestCase
  include ARVMTestUtilities
  extend Minitest::Spec::DSL

  include ViewModelSpecHelpers::ParentAndBelongsToChildWithMigration

  def new_model
    model_class.new(name: 'm1', child: child_model_class.new(name: 'c1'))
  end

  let(:viewmodel) { create_viewmodel! }

  let(:current_serialization) { ViewModel.serialize_to_hash(viewmodel) }

  let(:v2_serialization) do
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
      }
    }
  end

  let(:migration_versions) { { viewmodel_class => 2, child_viewmodel_class => 2 } }

  let(:down_migrator) { ViewModel::DownMigrator.new(migration_versions) }
  let(:up_migrator) { ViewModel::UpMigrator.new(migration_versions) }

  def migrate!
    migrator.migrate!(subject, references: {})
  end


  describe 'downwards' do
    let(:migrator) { down_migrator }
    let(:subject) { current_serialization.deep_dup }

    let(:expected_result) do
      v2_serialization.deep_merge(
        {
          ViewModel::MIGRATED_ATTRIBUTE => true,
          'old_field' => -1,
          'child' => {
            ViewModel::MIGRATED_ATTRIBUTE => true,
            'former_field' => 'reconstructed'
          }
        }
      )
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
    let(:subject) { v2_serialization.deep_dup }

    let(:expected_result) do
      current_serialization.deep_merge(
        ViewModel::MIGRATED_ATTRIBUTE => true,
        'new_field' => 3,
        'child' => {
          ViewModel::MIGRATED_ATTRIBUTE => true,
        }
      )
    end

    it 'migrates' do
      migrate!

      assert_equal(expected_result, subject)
    end

    describe 'with version unspecified' do
      let(:subject) do
        v2_serialization
          .except(ViewModel::VERSION_ATTRIBUTE)
      end

      it 'treats it as the requested version' do
        migrate!
        assert_equal(expected_result, subject)
      end
    end

    describe 'with a version not in the specification' do
      let(:subject) do
        v2_serialization
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

      let(:subject) do
        v2_serialization.deep_merge(
          'child' => { ViewModel::VERSION_ATTRIBUTE => 1 }
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

      let(:subject) do
        v2_serialization.except('old_field').merge(ViewModel::VERSION_ATTRIBUTE => 1)
      end

      it 'raises' do
        assert_raises(ViewModel::Migration::OneWayError) do
          migrate!
        end
      end
    end
  end
end
