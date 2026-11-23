# frozen_string_literal: true

require "test_helper"

class LazyTest < Minitest::Test
  def test_needs_a_block
    assert_raises(ArgumentError) { RubyCdk::Lazy.new }
  end

  def test_resolves_once_with_the_stack
    calls = 0
    lazy = RubyCdk::Lazy.new { |stack| calls += 1; "value for #{stack}" }

    assert_equal "value for stack", lazy.resolve("stack")
    assert_equal "value for stack", lazy.resolve("stack")
    assert_equal 1, calls
  end

  def test_follows_a_chain_of_lazy_values
    bottom = RubyCdk::Lazy.new { "bottom" }
    top = RubyCdk::Lazy.new { RubyCdk::Lazy.new { bottom } }

    assert_equal "bottom", top.resolve(nil)
  end

  def test_each_lazy_in_a_chain_is_evaluated_once
    calls = 0
    bottom = RubyCdk::Lazy.new { calls += 1 }
    top = RubyCdk::Lazy.new { bottom }

    top.resolve(nil)
    top.resolve(nil)

    assert_equal 1, calls
  end

  def test_a_lazy_that_resolves_to_itself_is_an_error
    lazy = nil
    lazy = RubyCdk::Lazy.new { lazy }

    error = assert_raises(RubyCdk::Error) { lazy.resolve(nil) }

    assert_match(/itself/, error.message)
  end

  def test_a_cycle_through_another_lazy_is_an_error
    first = second = nil
    first = RubyCdk::Lazy.new { second }
    second = RubyCdk::Lazy.new { first }

    assert_raises(RubyCdk::Error) { first.resolve(nil) }
  end

  def test_a_chain_deeper_than_the_limit_is_an_error
    top = RubyCdk::Lazy.new { "bottom" }
    (RubyCdk::Lazy::MAX_DEPTH + 1).times do
      next_link = top
      top = RubyCdk::Lazy.new { next_link }
    end

    error = assert_raises(RubyCdk::Error) { top.resolve(nil) }

    assert_match(/deeper than/, error.message)
  end

  def test_a_chain_at_the_limit_resolves
    top = RubyCdk::Lazy.new { "bottom" }
    RubyCdk::Lazy::MAX_DEPTH.times do
      next_link = top
      top = RubyCdk::Lazy.new { next_link }
    end

    assert_equal "bottom", top.resolve(nil)
  end

  def test_a_failed_block_can_be_tried_again
    attempts = 0
    lazy = RubyCdk::Lazy.new do
      attempts += 1
      raise "not yet" if attempts == 1

      "now"
    end

    assert_raises(RuntimeError) { lazy.resolve(nil) }
    assert_equal "now", lazy.resolve(nil)
  end
end
