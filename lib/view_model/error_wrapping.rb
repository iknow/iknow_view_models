# frozen_string_literal: true

class ViewModel
  module ErrorWrapping
    extend ActiveSupport::Concern

    # Catch and translate ActiveRecord errors that map to standard ViewModel
    # errors. Blame may be either a single VM::Reference or an array of them, or
    # an empty array if there is no specific node that the error may be attached
    # to.
    def wrap_active_record_errors(blame)
      yield
    rescue ::ActiveRecord::RecordInvalid => e
      raise ViewModel::DeserializationError::Validation.from_active_model(e.record.errors, Array.wrap(blame))
    rescue ::ActiveRecord::StaleObjectError => _e
      raise ViewModel::DeserializationError::LockFailure.new(Array.wrap(blame))
    rescue ::ActiveRecord::QueryAborted, ::ActiveRecord::PreparedStatementCacheExpired, ::ActiveRecord::TransactionRollbackError => e
      raise ViewModel::DeserializationError::TransientDatabaseError.new(e.message, Array.wrap(blame))
    rescue ::ActiveRecord::StatementInvalid, ::ActiveRecord::InvalidForeignKey, ::ActiveRecord::RecordNotSaved => e
      raise ViewModel::DeserializationError::DatabaseConstraint.from_exception(e, Array.wrap(blame))
    end
  end
end
