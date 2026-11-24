# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/deploy"

# The engine polls for itself (architecture section 9): a first interval, a
# backoff, an overall limit, and a sleep that is injected so that no test waits.
class DeployPollerTest < Minitest::Test
  Poller = RubyCdk::Deploy::Poller

  # A poller that records its sleeps instead of sleeping: [poller, the sleeps].
  def poller(interval:, factor:, max_interval:, limit:)
    slept = []
    watcher = Poller.new(interval: interval, factor: factor, max_interval: max_interval, limit: limit, sleep: ->(seconds) { slept << seconds })
    [ watcher, slept ]
  end

  def test_it_returns_the_first_answer_that_is_not_nil
    calls = 0
    watcher, slept = poller(interval: 1, factor: 2, max_interval: 10, limit: 100)

    result = watcher.run do
      calls += 1
      :done if calls == 3
    end

    assert_equal :done, result
    assert_equal 3, calls
    assert_equal [ 1, 2 ], slept
  end

  def test_an_answer_on_the_first_call_sleeps_not_at_all
    watcher, slept = poller(interval: 1, factor: 2, max_interval: 10, limit: 100)

    assert_equal false, watcher.run { false }, "false is an answer; only nil means not yet"
    assert_equal [], slept
  end

  def test_the_interval_grows_and_stops_at_its_maximum
    calls = 0
    watcher, slept = poller(interval: 2, factor: 1.5, max_interval: 5, limit: 100)

    watcher.run do
      calls += 1
      :done if calls > 5
    end

    assert_equal [ 2, 3, 4.5, 5, 5 ], slept
  end

  def test_the_limit_ends_the_wait
    watcher, slept = poller(interval: 5, factor: 1, max_interval: 5, limit: 12)
    calls = 0

    error = assert_raises(RubyCdk::Deploy::WaitTimedOut) do
      watcher.run do
        calls += 1
        nil
      end
    end

    assert_match(/limit of 12 seconds/, error.message)
    assert_equal 1, RubyCdk::Deploy.exit_code_for(error)
    assert_equal [ 5, 5 ], slept, "two sleeps fit in the limit, a third would not"
    assert_equal 3, calls
  end

  def test_the_count_starts_again_at_each_wait
    calls = 0
    watcher, slept = poller(interval: 3, factor: 1, max_interval: 3, limit: 3)

    first = watcher.run do
      calls += 1
      :done if calls == 2
    end
    second = watcher.run { :again }

    assert_equal :done, first
    assert_equal :again, second
    assert_equal [ 3 ], slept
  end

  def test_the_default_sleep_is_ruby_sleep
    watcher = Poller.new(interval: 0.001, factor: 1, max_interval: 0.001, limit: 1)

    done = watcher.run do
      :done
    end

    assert_equal :done, done
  end

  def test_the_two_pollers_a_deploy_uses
    change_set = Poller.change_set
    operation = Poller.operation

    assert_equal Poller::CHANGE_SET_LIMIT, change_set.limit
    assert_equal Poller::OPERATION_LIMIT, operation.limit
    assert_operator change_set.limit, :<, operation.limit, "a change set is given up on long before a stack operation"
  end

  def test_the_one_for_tests_never_waits_and_still_gives_up
    calls = 0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(RubyCdk::Deploy::WaitTimedOut) do
      Poller.instant.run do
        calls += 1
        nil
      end
    end

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    assert_operator calls, :>, 1000
  end
end
