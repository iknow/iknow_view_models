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

    serialization = { 'data' => view }

    # Only include 'references' key if there are actually references to
    # serialize. This matches prerender_viewmodel.
    if ctx.has_references?
      serialization['references'] = ctx.serialize_references_to_hash
    end

    serialization
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

  let(:v2_serialization) do
    {
      'data' => v2_serialization_data,
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
      let(:subject) { { 'data' => subject_data } }

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

      describe 'with a functional update' do
        # note that this wouldn't actually be deserializable as child is not a collection
        def subject_data
          data = super()
          data['child'] = wrap_with_fupdate(data['child'])
          data
        end

        def expected_result
          data = super()
          data['data']['child'] = wrap_with_fupdate(data['data']['child'])
          data
        end

        def wrap_with_fupdate(child)
          # The 'after' and remove shouldn't get changed in migration, even though it has _type: Child
          build_fupdate do
            append([child], after: { '_type' => 'Child', 'id' => 9999 })
            update([child.deep_merge('id' => 8888)])
            remove([{ '_type' => 'Child', 'id' => 7777 }])
          end
        end

        it 'migrates' do
          migrate!
          assert_equal(expected_result, subject)
        end
      end
    end
  end

  describe 'inherited migrations' do
    include ViewModelSpecHelpers::SingleWithInheritedMigration

    def new_model
      model_class.new(name: 'm1')
    end

    let(:migration_versions) { { viewmodel_class => 1 } }

    let(:v1_serialization_data) do
      {
        ViewModel::TYPE_ATTRIBUTE => viewmodel_class.view_name,
        ViewModel::VERSION_ATTRIBUTE => 1,
        ViewModel::ID_ATTRIBUTE => viewmodel.id,
        'name' => viewmodel.name,
        'inherited_base' => 'present',
      }
    end

    let(:v1_serialization) do
      {
        'data' => v1_serialization_data,
      }
    end

    describe 'downwards' do
      let(:migrator) { down_migrator }
      let(:subject) { current_serialization.deep_dup }
      let(:expected_result) do
        v1_serialization.deep_merge({ 'data' => { ViewModel::MIGRATED_ATTRIBUTE => true } })
      end

      it 'migrates' do
        migrate!
        assert_equal(expected_result, subject)
      end
    end

    describe 'upwards' do
      let(:migrator) { up_migrator }
      let(:subject) { v1_serialization.deep_dup }

      let(:expected_result) do
        current_serialization.deep_merge(
          {
            'data' => {
              ViewModel::MIGRATED_ATTRIBUTE => true,
              'new_field' => 100,
            },
          },
        )
      end

      it 'migrates' do
        migrate!
        assert_equal(expected_result, subject)
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
          migrations do
            migrates from: 1, to: 2 do
              down do |view, refs|
                view.delete('child')
              end
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
          migrations do
            migrates from: 1, to: 2 do
              down do |view, _refs|
                view.delete('child')
              end
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
                      migrations do
                        migrates from: 1, to: 2 do
                        end
                        no_migration_from! 2
                        no_migration_from! 3
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

  describe 'changing references' do
    include ViewModelSpecHelpers::ParentAndBelongsToChild
    let(:migration_versions) { { viewmodel_class => 1 } }

    let(:old_field_serialization) do
      {
        ViewModel::TYPE_ATTRIBUTE    => 'SyntheticType',
        ViewModel::VERSION_ATTRIBUTE => 1,
      }
    end

    def model_attributes
      old_field_serialization = self.old_field_serialization
      super.merge(
        viewmodel: ->(_v) {
          self.schema_version = 2

          migrations do
            # The migration from 1 -> 2 deleted a referenced field.
            migrates from: 1, to: 2 do
              # Put the referenced field back with a canned serialization
              down do |view, refs|
                view['old_field'] = { ViewModel::REFERENCE_ATTRIBUTE => 'ref:old_field' }
                refs['ref:old_field'] = old_field_serialization
              end

              # Remove the referenced field
              up do |view, _refs|
                view.delete('old_field')
              end
            end
          end
        },
      )
    end

    let(:v1_serialization_data) do
      base = {
        ViewModel::TYPE_ATTRIBUTE => viewmodel_class.view_name,
        ViewModel::VERSION_ATTRIBUTE => 1,
        ViewModel::ID_ATTRIBUTE => viewmodel.id,
        'name' => viewmodel.name,
        'child' => {
          ViewModel::TYPE_ATTRIBUTE => child_viewmodel_class.view_name,
          ViewModel::VERSION_ATTRIBUTE => 1,
          ViewModel::ID_ATTRIBUTE => viewmodel.child.id,
          'name' => viewmodel.child.name,
        },
        'old_field' => { ViewModel::REFERENCE_ATTRIBUTE => 'ref:old_field' },
      }
    end

    let(:v1_serialization_references) do
      { 'ref:old_field' => old_field_serialization }
    end

    let(:v1_serialization) do
      {
        'data' => v1_serialization_data,
        'references' => v1_serialization_references,
      }
    end

    describe 'adding references' do
      let(:migrator) { down_migrator }
      let(:subject) do
        ser = current_serialization.deep_dup
        raise ArgumentError.new('Expected no references') if ser.has_key?('references')

        ser
      end

      let(:expected_result) do
        {
          'data' => v1_serialization_data.deep_dup.deep_merge(
            { ViewModel::MIGRATED_ATTRIBUTE => true },
          ),
          'references' => v1_serialization_references,
        }
      end

      it 'migrates and returns references' do
        migrate!

        assert_equal(expected_result, subject)
      end
    end

    describe 'removing references' do
      let(:migrator) { up_migrator }
      let(:subject) do
        ser = v1_serialization.deep_dup
        raise ArgumentError.new('Expected references') unless ser.has_key?('references')

        ser
      end

      let(:expected_result) do
        {
          'data' => current_serialization.fetch('data').deep_dup.merge({
            ViewModel::MIGRATED_ATTRIBUTE => true,
          }),
          # references key is absent
        }
      end

      it 'migrates and returns references' do
        migrate!

        assert_equal(expected_result, subject)
      end
    end
  end

  describe 'concurrently inserting a reference' do
    include ViewModelSpecHelpers::ReferencedList
    let(:migration_versions) { { viewmodel_class => 1 } }

    # Use a list with two members
    def new_model
      model_class.new(name: 'root',
                      next: model_class.new(name: 'old-tail'))
    end

    # Define a down migration that matches the old tail to insert a new tail
    # after it, and the new tail to change its name.
    def model_attributes
      super.merge(
        viewmodel: ->(v) {
          self.schema_version = 2

          migrations do
            migrates from: 1, to: 2 do
              down do |view, refs|
                case view['name']
                when 'old-tail'
                  view['next'] = { ViewModel::REFERENCE_ATTRIBUTE => 'ref:s:new_tail' }
                  refs['ref:s:new_tail'] = {
                    ViewModel::TYPE_ATTRIBUTE    => v.view_name,
                    ViewModel::VERSION_ATTRIBUTE => v.schema_version,
                    'id' => 100, # entirely fake
                    'name' => 'new-tail',
                    'next' => nil,
                  }

                when 'new-tail'
                  view['name'] = 'newer-tail'
                end
              end
            end
          end
        },
      )
    end

    let(:v1_serialization_data) do
      {
        ViewModel::TYPE_ATTRIBUTE => viewmodel_class.view_name,
        ViewModel::VERSION_ATTRIBUTE => 1,
        ViewModel::ID_ATTRIBUTE => viewmodel.id,
        'name' => viewmodel.name,
        'next' => { ViewModel::REFERENCE_ATTRIBUTE => viewmodel.next.to_reference.stable_reference },
        ViewModel::MIGRATED_ATTRIBUTE => true,
      }
    end

    let(:v1_serialization_references) do
      old_tail = viewmodel.next
      old_tail_ref = old_tail.to_reference.stable_reference
      {
        old_tail_ref => {
          ViewModel::TYPE_ATTRIBUTE => viewmodel_class.view_name,
          ViewModel::VERSION_ATTRIBUTE => 1,
          ViewModel::ID_ATTRIBUTE => old_tail.id,
          'name' => 'old-tail',
          'next' => { ViewModel::REFERENCE_ATTRIBUTE => 'ref:s:new_tail' },
          ViewModel::MIGRATED_ATTRIBUTE => true,
        },
        'ref:s:new_tail' => {
          ViewModel::TYPE_ATTRIBUTE => viewmodel_class.view_name,
          ViewModel::VERSION_ATTRIBUTE => 1,
          ViewModel::ID_ATTRIBUTE => 100,
          'name' => 'newer-tail',
          'next' => nil,
          ViewModel::MIGRATED_ATTRIBUTE => true,
        },
      }
    end

    let(:v1_serialization) do
      {
        'data' => v1_serialization_data,
        'references' => v1_serialization_references,
      }
    end

    describe 'downwards' do
      let(:migrator) { down_migrator }
      let(:subject) { current_serialization.deep_dup }

      it 'migrates' do
        migrate!

        assert_equal(v1_serialization, subject)
      end
    end
  end
end
