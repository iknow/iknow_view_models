# frozen_string_literal: true

# Module implementing the behaviour of a AR post-transaction hook. After calling
# `add_to_transaction`, the abstract method `after_transaction` will be invoked
# by AR's callbacks.
module ViewModel::AfterTransactionRunner
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
      after_transaction
    end
  end

  # Override to tie to a specific connection.
  def connection
    ActiveRecord::Base.connection
  end
end
