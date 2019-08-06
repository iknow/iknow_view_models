# frozen_string_literal: true

# Module implementing the behaviour of a AR post-transaction hook. After calling
# `add_to_transaction`, the abstract method `after_transaction` will be invoked
# by AR's callbacks.
module ViewModel::AfterTransactionRunner
  def committed!(*); end

  def before_committed!
    after_transaction
  end

  def rolledback!(*)
    after_transaction
  end

  def add_to_transaction
    if connection.transaction_open?
      connection.add_transaction_record(self)
    else
      after_transaction
    end
  end

  def trigger_transactional_callbacks?
    true
  end

  # Override to tie to a specific connection.
  def connection
    ActiveRecord::Base.connection
  end
end
