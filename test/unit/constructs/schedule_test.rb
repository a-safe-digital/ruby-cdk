# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/constructs"
require "support/core_helpers"

# This tool's own tests of the schedule, what no CDK case reaches here
# (docs/07-testing.md section 10): the expression strings of rate and cron,
# the CDK's defaults spelled out, and the refusals.
class ConstructsScheduleTest < CoreHelpers::TestCase
  def test_rate_takes_the_number_and_the_unit
    assert_equal "rate(10 minutes)", RubyCdk::Events::Schedule.rate(10, :minutes).expression_string
    assert_equal "rate(2 hours)", RubyCdk::Events::Schedule.rate(2, :hours).expression_string
    assert_equal "rate(1 day)", RubyCdk::Events::Schedule.rate(1, :days).expression_string
  end

  def test_rate_refuses_zero_and_the_units_it_does_not_take
    assert_raises(RubyCdk::UsageError) { RubyCdk::Events::Schedule.rate(0, :minutes) }
    assert_raises(RubyCdk::UsageError) { RubyCdk::Events::Schedule.rate(-1, :days) }
    assert_raises(RubyCdk::UsageError) { RubyCdk::Events::Schedule.rate(5, :seconds) }
    assert_raises(RubyCdk::UsageError) { RubyCdk::Events::Schedule.rate(5, "minutes") }
  end

  def test_cron_defaults_the_six_fields_as_the_cdk_does
    assert_equal "cron(* * * * ? *)", RubyCdk::Events::Schedule.cron.expression_string
    assert_equal "cron(* 8 * * ? *)", RubyCdk::Events::Schedule.cron(hour: "8").expression_string
    assert_equal "cron(0 8 1 * ? *)", RubyCdk::Events::Schedule.cron(minute: "0", hour: "8", day: "1").expression_string
    assert_equal "cron(* * ? * 2 *)", RubyCdk::Events::Schedule.cron(week_day: "2").expression_string
  end

  def test_cron_refuses_day_with_week_day_and_non_string_fields
    assert_raises(RubyCdk::UsageError) do
      RubyCdk::Events::Schedule.cron(day: "1", week_day: "2")
    end
    assert_raises(RubyCdk::UsageError) do
      RubyCdk::Events::Schedule.cron(hour: 8)
    end
  end

  def test_expression_takes_a_non_empty_string_only
    assert_equal "rate(1 hour)", RubyCdk::Events::Schedule.expression("rate(1 hour)").expression_string
    assert_raises(RubyCdk::UsageError) { RubyCdk::Events::Schedule.expression("") }
    assert_raises(RubyCdk::UsageError) { RubyCdk::Events::Schedule.expression(nil) }
  end
end
