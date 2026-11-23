# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/matching/lib/capture.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: the constructor's optional pattern is RubyCdk::Test::UNDEFINED when
#   it is not given, which is what `pattern?: any` is there. The array the CDK
#   keeps in a public field marked @internal (`_captured`) is private here; the
#   engine fills it through _append_captures, which is internal as well.

require_relative "match"
require_relative "matcher"
require_relative "private/error"
require_relative "private/js"
require_relative "private/type"

module RubyCdk
  module Test
    # Capture values while matching templates.
    # Using an instance of this class within a Matcher will capture the matching value.
    # The `as*()` APIs on the instance can be used to get the captured value.
    class Capture < Matcher
      attr_reader :name

      # Initialize a new capture.
      #
      # pattern: a nested pattern or Matcher. If a nested pattern is provided,
      # `object_like()` matching is applied.
      def initialize(pattern = UNDEFINED)
        @name = "Capture"
        @pattern = pattern
        @captured = []
        @index = 0
      end

      def test(actual)
        result = MatchResult.new(actual)
        if Private::Js.nullish?(actual)
          return result.record_failure(matcher: self, path: [], message: "Can only capture non-nullish values. Found #{Private::Js.string(actual)}")
        end

        unless @pattern.equal?(UNDEFINED)
          inner_matcher = Matcher.matcher?(@pattern) ? @pattern : Match.object_like(@pattern)
          inner_result = inner_matcher.test(actual)
          return inner_result if inner_result.has_failed?
        end

        result.record_capture(capture: self, value: actual)
        result
      end

      # When multiple results are captured, move the iterator to the next result.
      # Returns true if another capture is present, false otherwise.
      def next
        if @index < @captured.length - 1
          @index += 1
          return true
        end
        false
      end

      # Retrieve the captured value as a string.
      # An error is generated if no value is captured or if the value is not a string.
      def as_string
        validate
        value = @captured[@index]
        return value if Private.get_type(value) == "string"

        report_incorrect_type("string")
      end

      # Retrieve the captured value as a number.
      # An error is generated if no value is captured or if the value is not a number.
      def as_number
        validate
        value = @captured[@index]
        return value if Private.get_type(value) == "number"

        report_incorrect_type("number")
      end

      # Retrieve the captured value as a boolean.
      # An error is generated if no value is captured or if the value is not a boolean.
      def as_boolean
        validate
        value = @captured[@index]
        return value if Private.get_type(value) == "boolean"

        report_incorrect_type("boolean")
      end

      # Retrieve the captured value as an array.
      # An error is generated if no value is captured or if the value is not an array.
      def as_array
        validate
        value = @captured[@index]
        return value if Private.get_type(value) == "array"

        report_incorrect_type("array")
      end

      # Retrieve the captured value as a JSON object.
      # An error is generated if no value is captured or if the value is not an object.
      def as_object
        validate
        value = @captured[@index]
        return value if Private.get_type(value) == "object"

        report_incorrect_type("object")
      end

      # Internal to the engine, not part of the public API: what MatchResult#finished hands over.
      def _append_captures(values)
        @captured.concat(values)
        nil
      end

      private

      def validate
        raise AssertionError, "No value captured" if @captured.empty?
      end

      def report_incorrect_type(expected)
        raise AssertionError,
          "Captured value is expected to be #{expected} but found #{Private.get_type(@captured[@index])}. " \
          "Value is #{Private::Js.json(@captured[@index], 2)}"
      end
    end
  end
end
