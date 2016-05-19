# Test mixin that allows queries executed in a block to be introspected.
#
# Code run within a `log_queries` block will collect data. Collected data is
# inspected via `logged_queries` which returns everything, or via
# `logged_named_queries`, which returns only valid payload names.
#
# Caveats: only supports single threaded testing.

if ActiveSupport::VERSION::MAJOR >= 4
  require 'active_support/subscriber'
  module QueryLogging
    # ActiveRecord integration
    class QueryLogger < ActiveSupport::Subscriber
      @log              = false
      @query_log        = []

      attach_to :active_record

      def self.clear!
        @query_log = []
      end

      def self.with_query_log
        clear!
        @log = true
        yield
      ensure
        @log = false
      end

      def self.log?
        @log
      end

      def self.logged_events
        @query_log
      end

      # All public methods are event handlers. The instance defines what to log,
      # while the class defines how to handle it.

      def sql(event)
        if self.class.log?
          self.class.logged_events << event
        end
      end
    end
  end
else
  class QueryLogger
    def self.clear!
    end
    def logged_events
      []
    end
  end
end

module QueryLogging
  # Defensively clean up before every test.
  def setup
    super
    QueryLogger.clear!
  end

  # Test helpers

  def log_queries
    QueryLogger.with_query_log { yield }
  end

  def logged_queries
    QueryLogger.logged_events
  end

  def logged_load_queries
    QueryLogger.logged_events
      .map { |x| x.payload[:name] }
      .select { |x| x && x =~ / Load$/ }
  end

  def have_query_logging?
    QueryLogging.const_defined?(:QueryLogger, false)
  end
end
