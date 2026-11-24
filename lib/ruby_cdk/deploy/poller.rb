# frozen_string_literal: true

require_relative "errors"

module RubyCdk
  module Deploy
    # The engine's own polling: a first interval, a backoff, and an overall
    # limit. The SDK's waiters do the same with a fixed 30-second delay.
    #
    # The sleep is a callable, so a test never waits. The limit is measured on
    # the time spent sleeping, which makes it exact whatever the clock does.
    class Poller
      # Gives up on a change set that CloudFormation has not described within
      # this many seconds (the SDK's waiter allows an hour).
      CHANGE_SET_LIMIT = 900

      # A stack operation can run for hours. This is the longest the engine follows one.
      OPERATION_LIMIT = 4 * 60 * 60

      attr_reader :limit

      # sleep is called with a number of seconds.
      def initialize(interval:, factor:, max_interval:, limit:, sleep: nil)
        @interval = interval
        @factor = factor
        @max_interval = max_interval
        @limit = limit
        @sleep = sleep || ->(seconds) { Kernel.sleep(seconds) }
        @waited = 0.0
        @delay = interval
      end

      def self.change_set
        new(interval: 1, factor: 1.5, max_interval: 15, limit: CHANGE_SET_LIMIT)
      end

      def self.operation
        new(interval: 2, factor: 1.5, max_interval: 10, limit: OPERATION_LIMIT)
      end

      # For tests, which script every answer: it never really waits, and it still
      # gives up, so a test that forgot the last answer fails instead of hanging.
      def self.instant
        new(interval: 0.001, factor: 1, max_interval: 0.001, limit: 2, sleep: ->(_seconds) { })
      end

      # Calls the block until it returns something other than nil, pausing in
      # between. Returns what the block returned. Raises WaitTimedOut when the
      # limit passes first.
      def run
        @waited = 0.0
        @delay = @interval
        loop do
          result = yield
          return result unless result.nil?

          pause
        end
      end

      def pause
        if @waited + @delay > @limit
          raise WaitTimedOut, "the limit of #{@limit} seconds passed"
        end

        @sleep.call(@delay)
        @waited += @delay
        @delay = [ @delay * @factor, @max_interval ].min
      end
    end
  end
end
