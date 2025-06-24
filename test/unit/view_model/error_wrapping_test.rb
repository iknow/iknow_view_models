# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/unit'
require 'minitest/hooks'
require 'rspec/expectations/minitest_integration'

require_relative '../../helpers/arvm_test_utilities'
require_relative '../../helpers/arvm_test_models'
require_relative '../../helpers/viewmodel_spec_helpers'

require 'view_model'
require 'view_model/active_record'

class ViewModel::ErrorWrappingTest < ActiveSupport::TestCase
  include ARVMTestUtilities
  extend Minitest::Spec::DSL

  class Subject
    include ViewModel::ErrorWrapping
  end

  let(:subject) { Subject.new }

  describe 'wrap_active_record_errors' do
    include ViewModelSpecHelpers::ParentAndBelongsToChild

    let(:blame) { ViewModel::Reference.new(viewmodel_class, nil) }

    describe 'RecordInvalid' do
      before do
        model_class.send(:validates, :name, inclusion: { in: ['cat'] })
      end

      it 'wraps the error' do
        ex = assert_raises(ViewModel::DeserializationError::Validation) do
          subject.wrap_active_record_errors(blame) do
            model_class.create!(name: 'a')
          end
        end

        expect(ex.attribute).to eq('name')
        expect(ex.reason).to match(/not included/)
        expect(ex.details).to include(error: :inclusion)
      end
    end

    describe 'StaleObjectError' do
      def model_attributes
        super.merge(
          schema: ->(t) { t.integer :lock_version, default: 0, null: false },
        )
      end

      it 'wraps the error' do
        model = model_class.create!(name: 'a')
        assert_raises(ViewModel::DeserializationError::LockFailure) do
          subject.wrap_active_record_errors(blame) do
            model.name = 'yes'
            model.lock_version = 10
            model.save!
          end
        end
      end
    end

    describe 'transient' do
      def with_timeout(timeout, conn = ActiveRecord::Base.connection, &block)
        original_timeout = conn.select_value('SHOW statement_timeout')
        conn.execute("SET SESSION statement_timeout = #{conn.quote(timeout)}")
        block.call(conn)
      ensure
        begin
          conn.execute("SET SESSION statement_timeout = #{conn.quote(original_timeout)}")
        rescue ActiveRecord::StatementInvalid => e
          raise unless e.cause.is_a?(PG::InFailedSqlTransaction)
        end
      end

      it 'wraps the error' do
        assert_raises(ViewModel::DeserializationError::TransientDatabaseError) do
          subject.wrap_active_record_errors(blame) do
            with_timeout(1) do
              ActiveRecord::Base.connection.execute('SELECT pg_sleep(10)')
            end
          end
        end
      end
    end

    describe 'check constraint' do
      def model_attributes
        super.merge(
          schema: ->(t) { t.check_constraint "name = 'cat'" },
        )
      end

      it 'wraps the error' do
        ex = assert_raises(ViewModel::DeserializationError::DatabaseConstraint) do
          subject.wrap_active_record_errors(blame) do
            model_class.create!(name: 'a')
          end
        end

        expect(ex.message).to match(/violates check constraint/)
      end
    end

    describe 'unique constraint' do
      def model_attributes
        super.merge(
          schema: ->(t) { t.index :name, unique: true },
        )
      end

      it 'wraps the error' do
        model_class.create!(name: 'a')

        ex = assert_raises(ViewModel::DeserializationError::UniqueViolation) do
          subject.wrap_active_record_errors(blame) do
            model_class.create!(name: 'a')
          end
        end

        expect(ex.columns).to eq(['name'])
      end
    end
  end
end
