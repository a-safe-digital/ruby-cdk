# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/matching/lib/match.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: camelCase to snake_case, the names of the matchers included, so that
#   a message names the method the user called: arrayWith() is array_with().
#   `not` is `not_`, because `not` is a Ruby keyword (as Fn.not_). Match is a
#   module and its factories are module functions. The classes LiteralMatch to
#   StringLikeRegexpMatch, which that file keeps to itself, are under Private.
#   Before matching, the Symbols of a pattern become strings (Js.normalize).
#   Where JavaScript throws one of its own TypeErrors (a null where an object was
#   needed), this port throws a Ruby TypeError with the same message.

require_relative "matcher"
require_relative "private/absent"
require_relative "private/error"
require_relative "private/js"
require_relative "private/sorting"
require_relative "private/sparse_matrix"
require_relative "private/type"

module RubyCdk
  module Test
    # Partial and special matching during template assertions.
    #
    # In the CDK these are the static methods of `Match`. Here they are also on
    # RubyCdk::Test itself, which is where the documentation of this tool puts them.
    module Match
      class << self
        # Use this matcher in the place of a field's value, if the field must not be present.
        def absent
          Private::AbsentMatch.new("absent")
        end

        # Matches the specified pattern with the array found in the same relative
        # path of the target. The set of elements (or matchers) must be in the same
        # order as would be found.
        #
        # pattern: the pattern to match
        def array_with(pattern)
          Private::ArrayMatch.new("array_with", Private::Js.normalize(pattern))
        end

        # Matches the specified pattern with the array found in the same relative
        # path of the target. The set of elements (or matchers) must match exactly
        # and in order.
        #
        # pattern: the pattern to match
        def array_equals(pattern)
          Private::ArrayMatch.new("array_equals", Private::Js.normalize(pattern), subsequence: false)
        end

        # Deep exact matching of the specified pattern to the target.
        #
        # pattern: the pattern to match
        def exact(pattern)
          Private::LiteralMatch.new("exact", Private::Js.normalize(pattern))
        end

        # Matches the specified pattern to an object found in the same relative path
        # of the target. The keys and their values (or matchers) must be present in
        # the target but the target can be a superset.
        #
        # pattern: the pattern to match
        def object_like(pattern)
          Private::ObjectMatch.new("object_like", Private::Js.normalize(pattern))
        end

        # Matches the specified pattern to an object found in the same relative path
        # of the target. The keys and their values (or matchers) must match exactly
        # with the target.
        #
        # pattern: the pattern to match
        def object_equals(pattern)
          Private::ObjectMatch.new("object_equals", Private::Js.normalize(pattern), partial: false)
        end

        # Matches any target which does NOT follow the specified pattern.
        #
        # pattern: the pattern to NOT match
        def not_(pattern)
          Private::NotMatch.new("not", Private::Js.normalize(pattern))
        end

        # Matches any string-encoded JSON and applies the specified pattern after parsing it.
        #
        # pattern: the pattern to match after parsing the encoded JSON.
        def serialized_json(pattern)
          Private::SerializedJson.new("serialized_json", Private::Js.normalize(pattern))
        end

        # Matches any non-null value at the target.
        def any_value
          Private::AnyMatch.new("any_value")
        end

        # Matches targets according to a regular expression.
        def string_like_regexp(pattern)
          Private::StringLikeRegexpMatch.new("string_like_regexp", pattern)
        end
      end
    end

    module Private
      # A Match class that expects the target to match with the pattern exactly.
      # The pattern may be nested with other matchers that are then delegated to.
      class LiteralMatch < Matcher
        attr_reader :name

        # partial_objects: whether objects nested at any level should be matched
        # partially. False unless given.
        def initialize(name, pattern, partial_objects: false)
          @name = name
          @pattern = pattern
          @partial_objects = partial_objects

          if Matcher.matcher?(@pattern)
            raise AssertionError, "LiteralMatch cannot directly contain another matcher. Remove the top-level matcher or nest it more deeply."
          end
        end

        def test(actual)
          if @pattern.is_a?(Array)
            return ArrayMatch.new(@name, @pattern, subsequence: false, partial_objects: @partial_objects).test(actual)
          end

          if Js.typeof(@pattern) == "object"
            return ObjectMatch.new(@name, @pattern, partial: @partial_objects).test(actual)
          end

          result = MatchResult.new(actual)
          if Js.typeof(@pattern) != Js.typeof(actual)
            return result.record_failure(matcher: self, path: [], message: "Expected type #{Js.typeof(@pattern)} but received #{Private.get_type(actual)}")
          end

          unless Js.strict_equal?(actual, @pattern)
            result.record_failure(matcher: self, path: [], message: "Expected #{Js.string(@pattern)} but received #{Js.string(actual)}")
          end

          result
        end
      end

      # Match class that matches arrays.
      class ArrayMatch < Matcher
        attr_reader :name

        # subsequence:      whether the pattern is a subsequence of the target: a
        #                   sequence that can be derived from another by deleting
        #                   some or no elements without changing the order of the
        #                   rest. True unless given.
        # partial_objects:  whether to continue matching objects inside the array
        #                   partially. False unless given.
        def initialize(name, pattern, subsequence: true, partial_objects: false)
          @name = name
          @pattern = pattern
          @subsequence = subsequence
          @partial_objects = partial_objects
        end

        def test(actual)
          unless actual.is_a?(Array)
            return MatchResult.new(actual).record_failure(matcher: self, path: [], message: "Expected type array but received #{Private.get_type(actual)}")
          end

          @subsequence ? test_subsequence(actual) : test_full_array(actual)
        end

        private

        def matcher_for(pattern_element)
          Matcher.matcher?(pattern_element) ? pattern_element : LiteralMatch.new(@name, pattern_element, partial_objects: @partial_objects)
        end

        def test_full_array(actual)
          result = MatchResult.new(actual)

          index = 0
          while index < @pattern.length && index < actual.length
            result.compose(index.to_s, matcher_for(@pattern[index]).test(actual[index]))
            index += 1
          end

          if index < @pattern.length
            result.record_failure(
              matcher: self,
              message: "Not enough elements in array (expecting #{@pattern.length}, got #{actual.length})",
              path: [ index.to_s ]
            )
          end
          if index < actual.length
            result.record_failure(
              matcher: self,
              message: "Too many elements in array (expecting #{@pattern.length}, got #{actual.length})",
              path: [ index.to_s ]
            )
          end

          result
        end

        def test_subsequence(actual)
          result = MatchResult.new(actual)

          # For subsequences, there is a lot of testing and backtracking that
          # happens here; keep track of it all so we can report in a sensible
          # amount of detail on what we did if the match happens to fail.
          pattern_index = 0
          actual_index = 0
          matches = SparseMatrix.new

          while pattern_index < @pattern.length && actual_index < actual.length
            matcher = matcher_for(@pattern[pattern_index])

            matcher_name = matcher.name
            if matcher_name == "absent" || matcher_name == "any_value"
              # array subsequence matcher is not compatible with anyValue() or absent() matcher. They don't make sense to be used together.
              raise AssertionError, "The Matcher #{matcher_name}() cannot be nested within array_with()"
            end

            inner_result = matcher.test(actual[actual_index])
            matches.set(pattern_index, actual_index, inner_result)

            actual_index += 1
            if inner_result.is_success?
              result.compose(actual_index.to_s, inner_result) # Record any captures
              pattern_index += 1
            end
          end

          # If we haven't matched all patterns:
          # - Report on each one that did match on where it matched (perhaps it was wrong)
          # - Report the closest match for the failing one
          if pattern_index < @pattern.length
            # Succeeded Pattern Index
            (0...pattern_index).each do |succeeded|
              found_match = matches.row(succeeded).find { |_index, inner| inner.is_success? }
              next unless found_match # Should never fail but let's be defensive

              index = found_match[0]

              result.compose(
                index.to_s,
                MatchResult.new(actual[index]).record_failure(
                  matcher: self,
                  message: "array_with pattern #{succeeded} matched here",
                  path: [],
                  cost: 0 # This is an informational message so it would be unfair to assign it cost
                )
              )
            end

            failed_matches = matches.row(pattern_index)
            failed_matches = failed_matches.sort(&Private.sort_key_comparator { |index, inner| [ inner.fail_cost, index ] })
            if failed_matches.length > 0
              index, closest = failed_matches[0]
              result.record_failure(
                matcher: self,
                message: "Could not match array_with pattern #{pattern_index}. This is the closest match",
                path: [ index.to_s ],
                cost: 0 # Informational message
              )
              result.compose(index.to_s, closest)
            else
              # The previous matcher matched at the end of the pattern and we didn't even get to try anything
              result.record_failure(
                matcher: self,
                message: "Could not match array_with pattern #{pattern_index}. No more elements to try",
                path: [ actual.length.to_s ]
              )
            end
          end

          result
        end
      end

      # Match class that matches objects.
      class ObjectMatch < Matcher
        attr_reader :name

        # partial: whether the pattern should partially match with the target
        # object, which can then contain more keys than the pattern expects. True
        # unless given.
        def initialize(name, pattern, partial: true)
          @name = name
          @pattern = pattern
          @partial = partial
        end

        def test(actual)
          unless Js.typeof(actual) == "object" && !actual.is_a?(Array)
            return MatchResult.new(actual).record_failure(matcher: self, path: [], message: "Expected type object but received #{Private.get_type(actual)}")
          end

          result = MatchResult.new(actual)
          unless @partial
            Js.object_keys(actual).each do |key|
              result.record_failure(matcher: self, path: [ key ], message: "Unexpected key #{key}") unless Js.in?(key, @pattern)
            end
          end

          Js.entries(@pattern).each do |pattern_key, pattern_value|
            if !Js.in?(pattern_key, actual) && !pattern_value.is_a?(AbsentMatch)
              result.record_failure(matcher: self, path: [ pattern_key ], message: "Missing key '#{pattern_key}'")
              next
            end

            result.compose(pattern_key, matcher_for(pattern_value).test(Js.get(actual, pattern_key)))
          end

          result
        end

        private

        def matcher_for(pattern_value)
          Matcher.matcher?(pattern_value) ? pattern_value : LiteralMatch.new(@name, pattern_value, partial_objects: @partial)
        end
      end

      class SerializedJson < Matcher
        attr_reader :name

        def initialize(name, pattern)
          @name = name
          @pattern = pattern
        end

        def test(actual)
          unless Private.get_type(actual) == "string"
            return MatchResult.new(actual).record_failure(matcher: self, path: [], message: "Expected JSON as a string but found #{Private.get_type(actual)}")
          end

          begin
            parsed = JSON.parse(actual, max_nesting: false)
          rescue JSON::ParserError
            return MatchResult.new(actual).record_failure(matcher: self, path: [], message: "Invalid JSON string: #{actual}")
          end

          matcher = Matcher.matcher?(@pattern) ? @pattern : LiteralMatch.new(@name, @pattern)
          inner_result = matcher.test(parsed)
          if inner_result.has_failed?
            inner_result.record_failure(matcher: self, path: [], message: "Encoded JSON value does not match")
          end

          inner_result
        end
      end

      class NotMatch < Matcher
        attr_reader :name

        def initialize(name, pattern)
          @name = name
          @pattern = pattern
        end

        def test(actual)
          matcher = Matcher.matcher?(@pattern) ? @pattern : LiteralMatch.new(@name, @pattern)

          inner_result = matcher.test(actual)
          result = MatchResult.new(actual)
          if inner_result.fail_count.zero?
            result.record_failure(matcher: self, path: [], message: "Found unexpected match: #{Js.json(actual, 2)}")
          end

          result
        end
      end

      class AnyMatch < Matcher
        attr_reader :name

        def initialize(name)
          @name = name
        end

        def test(actual)
          result = MatchResult.new(actual)
          if Js.nullish?(actual)
            result.record_failure(matcher: self, path: [], message: "Expected a value but found none")
          end

          result
        end
      end

      class StringLikeRegexpMatch < Matcher
        attr_reader :name

        def initialize(name, pattern)
          @name = name
          @pattern = pattern
        end

        def test(actual)
          result = MatchResult.new(actual)

          # JavaScript compiles it with the flags 'gm'. Ruby needs none: ^ and $
          # match at line ends there too, and `.` does not cross a newline.
          regex = Regexp.new(@pattern)

          unless actual.is_a?(String)
            result.record_failure(matcher: self, path: [], message: "Expected a string, but got '#{Js.typeof(actual)}'")
          end

          unless regex.match?(Js.string(actual))
            result.record_failure(matcher: self, path: [], message: "String '#{Js.string(actual)}' did not match pattern '#{@pattern}'")
          end

          result
        end
      end
    end
  end
end
