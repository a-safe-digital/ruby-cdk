# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/matching/lib/matcher.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: camelCase to snake_case, and a few names to Ruby's idiom for a
#   question: isMatcher(x) is Matcher.matcher?(x), the isSuccess getter is
#   is_success?, hasFailed() is has_failed?; finished() keeps its name, it does
#   something rather than ask. recordFailure takes its fields as keywords, which
#   is how Ruby writes the object literal it takes there. MatchFailure and
#   MatchCapture are Data. The functions nested in renderMismatch() are methods of
#   Private::MismatchRenderer, which reads three fields that the CDK keeps
#   private on MatchResult: failures_here, inner_match_failures and captures are
#   readers here, marked internal. push() is kept, deprecated as there.

require_relative "private/error"
require_relative "private/js"

module RubyCdk
  module Test
    # Represents a matcher that can perform special data matching capabilities
    # between a given pattern and a target.
    class Matcher
      # Whether the value is a Matcher.
      def self.matcher?(value)
        value.is_a?(Matcher)
      end

      # A name for the matcher. This is collected as part of the result and may be
      # presented to the user.
      def name
        raise NotImplementedError
      end

      # Test whether a target matches the provided pattern. Every Matcher must
      # implement this method. This method will be invoked by the assertions
      # framework. Do not call this method directly.
      #
      # Returns a MatchResult whose failures are the match failures: none when the
      # match succeeded.
      def test(actual)
        raise NotImplementedError
      end
    end

    # Match failure details.
    #
    #   matcher: the matcher that had the failure
    #   path:    where in the target. [] for the root of the match tree,
    #            [ "/foo", "[5]" ] for the 5th index of the array under key "foo"
    #   message: what did not match
    #   cost:    the cost of this particular mismatch: nil, counted as 1, unless given
    MatchFailure = Data.define(:matcher, :path, :message, :cost)

    # Information about a value captured during match: the Capture it belongs to,
    # and the value.
    MatchCapture = Data.define(:capture, :value)

    # The result of Matcher#test.
    class MatchResult
      # The target for which this result was generated.
      attr_reader :target

      # The number of failures.
      attr_reader :fail_count

      # Internal to the engine, not part of the public API: the failures of this
      # result by path, the results composed under this one by id, and the captures
      # recorded here by Capture.
      attr_reader :failures_here, :inner_match_failures, :captures

      def initialize(target)
        @target = target
        @failures_here = {}
        @inner_match_failures = {}
        @captures = {}
        @finalized = false
        @has_failed = false
        @fail_count = 0
        @cost = 0
      end

      # Deprecated in the CDK and here: record_failure.
      def push(matcher, path, message)
        record_failure(matcher: matcher, path: path, message: message)
      end

      # Record a new failure into this result at a specific path.
      def record_failure(matcher:, path:, message:, cost: nil)
        fail_key = path.join(".")
        (@failures_here[fail_key] ||= []) << MatchFailure.new(matcher: matcher, path: path, message: message, cost: cost)
        @fail_count += 1
        @cost += cost || 1
        @has_failed = true
        self
      end

      # Whether the match is a success.
      def is_success?
        !@has_failed
      end

      # Does the result contain any failures. If not, the result is a success.
      def has_failed?
        @has_failed
      end

      # The cost of the failures so far.
      def fail_cost
        @cost
      end

      # Compose the results of a previous match as a subtree.
      #
      # id: the id of the parent tree.
      def compose(id, inner)
        # Record inner failure
        if inner.has_failed?
          @has_failed = true
          @fail_count += inner.fail_count
          @cost += inner.fail_cost
          @inner_match_failures[id] = inner
        end

        # Copy captures so we all finalize them together
        inner.captures.each do |capture, values|
          values.each { |value| record_capture(capture: capture, value: value) }
        end
        self
      end

      # Prepare the result to be analyzed. This API *must* be called prior to
      # analyzing these results.
      def finished
        return self if @finalized

        if @fail_count.zero?
          @captures.each { |capture, values| capture._append_captures(values) }
        end
        @finalized = true
        self
      end

      # Render the failed match in a presentable way.
      #
      # Prefer render_mismatch over this method. It is left for backwards
      # compatibility for test suites that expect it, but render_mismatch will
      # produce better output.
      def to_human_strings
        failures = []
        collect_failures(self, [], failures)
        failures.map do |failure|
          location = failure.path.empty? ? "" : " at /#{failure.path.join("/")}"
          "#{failure.message}#{location} (using #{failure.matcher.name} matcher)"
        end
      end

      # Do a deep render of the match result, showing the structure mismatches in context.
      def render_mismatch
        Private::MismatchRenderer.new(self).render
      end

      # Record a capture against in this match result.
      def record_capture(capture:, value:)
        (@captures[capture] ||= []) << value
        nil
      end

      private

      def collect_failures(result, prefix, failures)
        result.failures_here.each_value do |fails|
          fails.each do |fail|
            failures << MatchFailure.new(matcher: fail.matcher, message: fail.message, path: prefix + fail.path, cost: fail.cost)
          end
        end
        result.inner_match_failures.each { |key, inner| collect_failures(inner, prefix + [ key ], failures) }
      end
    end

    module Private
      # The functions that the CDK nests inside MatchResult#renderMismatch(), as
      # methods of the object that does the rendering.
      class MismatchRenderer
        def initialize(result)
          @result = result
          @parts = []
          @indents = []
        end

        def render
          return "<match>" unless @result.has_failed?

          emit_failures(@result, "")
          recurse(@result)
          Js.move_markers_to_front(Js.trim_end(@parts.join))
        end

        private

        def emit(text)
          @parts << text.gsub("\n", "\n#{@indents.join}")
        end

        # The failures reported at a path, each on its own line, marked with !!.
        def emit_failures(result, path, scrap = nil)
          (result.failures_here[path] || []).each { |failure| emit("!! #{failure.message}\n") }
          scrap&.delete(path)
        end

        def recurse(result)
          # Failures that have been reported against this result that we did not print yet
          remaining = result.failures_here.keys.reject { |key| key == "" }

          if result.target.is_a?(Array)
            @indents.push("  ")
            emit("[\n")
            result.target.each_with_index do |_, index|
              emit(",\n") unless index.zero?

              emit_failures(result, index.to_s, remaining)
              inner = result.inner_match_failures[index.to_s]
              if inner
                # Report the top-level failures on the line before the content
                emit_failures(inner, "")
                recurse_comparing_values(inner, result.target[index])
              else
                emit(Js.render_abridged(result.target[index]))
              end
            end

            emit_remaining(result, remaining)
            @indents.pop
            emit("\n]")
            return
          end

          if Js.object?(result.target)
            @indents.push("  ")
            emit("{\n")
            keys = (Js.object_keys(result.target) + remaining).uniq.sort

            keys.each_with_index do |key, index|
              emit(",\n") unless index.zero?

              emit_failures(result, key, remaining)
              inner = result.inner_match_failures[key]
              if inner
                # Report the top-level failures on the line before the content
                emit_failures(inner, "")
                emit("#{Js.jsonify(key)}: ")
                recurse_comparing_values(inner, Js.get(result.target, key))
              else
                emit("#{Js.jsonify(key)}: ")
                emit(Js.render_abridged(Js.get(result.target, key)))
              end
            end

            emit_remaining(result, remaining)
            @indents.pop
            emit("\n}")
            return
          end

          emit_remaining(result, remaining)
          emit(Js.jsonify(result.target))
        end

        def emit_remaining(result, remaining)
          emit("\n") if remaining.any?

          remaining.each { |key| emit_failures(result, key) }
        end

        # Recurse to the inner matcher, but with a twist: when the match result's
        # target is not the value given here, the matcher matched a transformation
        # of that value (a parsed JSON string, for one), and both are rendered.
        def recurse_comparing_values(inner, actual_value)
          return recurse(inner) if Js.strict_equal?(inner.target, actual_value)

          emit(Js.render_abridged(actual_value))
          emit(" <*> ")
          recurse(inner)
        end
      end
    end
  end
end
