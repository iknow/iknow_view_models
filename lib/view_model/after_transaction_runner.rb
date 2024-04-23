# frozen_string_literal: true

# Module implementing the behaviour of a AR post-transaction hook. After calling
# `add_to_transaction`, the abstract method `after_transaction` will be invoked
# by AR's callbacks.
module ViewModel::AfterTransactionRunner
  extend ActiveSupport::Concern

  class_methods do
    # Rails 7.1+ expects after transaction hooks to declare whether to run the
    # hook on the first equivalent instance to be enqueued or the last one. For
    # ActiveRecord models, this class method is defined on ActiveRecord::Core
    # and delegates to Rails configuration. For us, we don't expect multiple
    # equivalent AfterTransactionRunners for the same callback, and opting into
    # the new behaviour would require implementing more of the ActiveRecord
    # model interface here such as #destroyed?, so we'll lock in the older
    # behavior that doesn't require so many inapplicable heuristics to identify
    # the last valid callback.
    def run_commit_callbacks_on_first_saved_instances_in_transaction
      true
    end
  end

  # Rails' internal API
  def committed!(*)
    after_commit
  end

  def before_committed!
    before_commit
  end

  def rolledback!(*)
    after_rollback
  end

  def trigger_transactional_callbacks?
    true
  end

  # Our simplified API

  def before_commit; end

  def after_commit; end

  def after_rollback; end

  def add_to_transaction
    if connection.transaction_open?
      connection.add_transaction_record(self)
    else
      before_commit
      after_commit
    end
  end

  # Override to tie to a specific connection.
  def connection
    ActiveRecord::Base.connection
  end
end
