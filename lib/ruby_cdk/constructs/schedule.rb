# frozen_string_literal: true

require_relative "../errors"

module RubyCdk
  module Events
    # A schedule for an EventBridge rule: the port of the CDK's Schedule
    # (aws-events/lib/schedule.ts), read at commit
    # c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   RubyCdk::Events::Schedule.rate(10, :minutes)   # "rate(10 minutes)"
    #   RubyCdk::Events::Schedule.cron(minute: "0", hour: "8")  # "cron(0 8 * * ? *)"
    #   RubyCdk::Events::Schedule.expression("rate(1 hour)")
    #
    # The CDK takes a Duration for rate and units are chosen from it - whole
    # days first, then hours, then minutes (schedule.ts:43-51). This tool has
    # no Duration; rate takes the number and the unit directly, the three the
    # CDK's literal path writes, plural (schedule.ts:45-51). A rate of 0 is
    # refused, as the CDK refuses one (schedule.ts:40-42).
    #
    # cron takes the six fields as Strings, with the CDK's defaults: "*" for
    # minute, hour, month and year, "?" for week_day, and day becomes "?"
    # when a week_day is given (schedule.ts:66-77). day and week_day cannot
    # go together (schedule.ts:57-59).
    #
    # What the CDK does that is not here: the warning it annotates on a cron
    # without a minute (schedule.ts:69-72) - this tool's constructs write no
    # annotations; the template is the whole output.
    class Schedule
      # The three units the CDK's literal rate path writes (schedule.ts:45-51).
      UNITS = %i[minutes hours days].freeze

      # The CDK's Schedule.expression (schedule.ts:29-31): a literal
      # expression, in a format EventBridge recognizes.
      def self.expression(expression)
        unless expression.is_a?(String) && !expression.empty?
          raise UsageError, "Schedule.expression takes a non-empty String, got #{expression.inspect}"
        end

        new(expression)
      end

      # A rate, the number and the unit: schedule.ts:34-52. Whole minutes,
      # hours or days, at least one. One takes the singular, as the CDK's
      # makeRate writes it (schedule.ts:163-165): "rate(1 day)",
      # "rate(10 minutes)".
      def self.rate(value, unit = :minutes)
        unless value.is_a?(Integer) && value.positive?
          raise UsageError, "Schedule.rate takes a positive Integer, got #{value.inspect}"
        end
        if UNITS.include?(unit)
          return new("rate(1 #{unit[0..-2]})") if value == 1

          return new("rate(#{value} #{unit})")
        end

        raise UsageError, "Schedule.rate takes #{UNITS.map(&:inspect).join(", ")}, got #{unit.inspect}"
      end

      # A cron, the six fields as Strings (schedule.ts:55-86): "cron(minute
      # hour day month weekDay year)". Fields default to "*" and week_day to
      # "?", and day goes "?" when a week_day names one.
      def self.cron(minute: nil, hour: nil, month: nil, year: nil, day: nil, week_day: nil)
        if day && week_day
          raise UsageError, "Cannot supply both 'day' and 'weekDay', use at most one"
        end
        [ minute, hour, month, year, day, week_day ].each do |field|
          next if field.nil? || field.is_a?(String)

          raise UsageError, "Schedule.cron takes its fields as Strings, got #{field.inspect}"
        end

        minute = fallback(minute, "*")
        hour = fallback(hour, "*")
        day = fallback(day, week_day ? "?" : "*")
        week_day = fallback(week_day, "?")
        new("cron(#{minute} #{hour} #{day} #{fallback(month, "*")} #{week_day} #{fallback(year, "*")})")
      end

      def self.fallback(value, default)
        value.nil? ? default : value
      end
      private_class_method :fallback

      attr_reader :expression_string

      def initialize(expression_string)
        @expression_string = expression_string
      end
    end
  end
end
