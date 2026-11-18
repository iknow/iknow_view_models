# frozen_string_literal: true

require_relative '../../../test_helper'

require 'pg'
require 'view_model'
require 'view_model/deserialization_error'

class ViewModel::DeserializationError::DatabaseConstraintTest < ActiveSupport::TestCase
  extend Minitest::Spec::DSL

  describe 'from_exception' do
    let(:error) { ViewModel::DeserializationError::DatabaseConstraint.from_exception(exception) }

    describe 'without a Postgres error' do
      let(:exception) do
        ActiveRecord::StatementInvalid.new(
          %(PG::CheckViolation: ERROR:  new row for relation "t" violates check constraint "c"\nDETAIL:  Failing row contains (1, SECRET).\n))
      end

      it 'redacts everything from the failing row' do
        expect(error.detail).to eq(
          %(PG::CheckViolation: ERROR:  new row for relation "t" violates check constraint "c"\nDETAIL:  Failing row contains (redacted).))
      end
    end

    describe 'without a failing row' do
      let(:exception) do
        ActiveRecord::StatementInvalid.new(%(PG::ForeignKeyViolation: ERROR:  insert or update on table "t" violates foreign key constraint "fk"))
      end

      it 'retains the message' do
        expect(error.detail).to eq(exception.message)
      end
    end
  end
end
