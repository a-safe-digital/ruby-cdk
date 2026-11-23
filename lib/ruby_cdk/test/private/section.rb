# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/lib/private/section.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: camelCase to snake_case. matchSection returns one value, a
#   SectionMatch, where the CDK returns a MatchSuccess or a MatchFailure: matches
#   is nil on a failure and closest_results on a success. The functions are module
#   functions of Private.

require_relative "../match"
require_relative "../matcher"
require_relative "js"
require_relative "sorting"

module RubyCdk
  module Test
    module Private
      # What came out of matching every entry of one section of a template against
      # the same matcher.
      #
      #   match:           whether at least one entry matched
      #   matches:         on a success, the entries that matched, by logical ID
      #   closest_results: on a failure, the three entries that came closest, each
      #                    with its MatchResult
      #   analyzed:        every entry the matcher was run against
      #   analyzed_count:  how many
      SectionMatch = Data.define(:match, :matches, :closest_results, :analyzed, :analyzed_count)

      module_function

      def match_section(section, props)
        matcher = Matcher.matcher?(props) ? props : Match.object_like(props)
        matching = {}
        analyzed = {}
        failures = []

        each_entry_in_section(section) do |logical_id, entry|
          analyzed[logical_id] = entry
          result = matcher.test(entry)
          result.finished
          if !result.has_failed?
            matching[logical_id] = entry
          else
            failures << [ logical_id, result ]
          end
        end

        if matching.keys.length > 0
          SectionMatch.new(match: true, matches: matching, closest_results: nil, analyzed_count: analyzed.keys.length, analyzed: analyzed)
        else
          # Sort by cost, use logicalId as a tie breaker. Take the 3 closest
          # matches (helps debugging in case we get the top pick wrong).
          failures.sort!(&sort_key_comparator { |logical_id, result| [ result.fail_cost, logical_id ] })
          SectionMatch.new(match: false, matches: nil, closest_results: failures.first(3).to_h, analyzed_count: analyzed.keys.length, analyzed: analyzed)
        end
      end

      def format_all_matches(matches)
        left_pad(Js.json(matches, 2))
      end

      def format_all_mismatches(analyzed, matches = {})
        [ "The following resources do not match the given definition:", *Js.object_keys(analyzed).reject { |id| Js.in?(id, matches) }.map { |id| "\t#{id}" } ].join("\n")
      end

      def format_section_match_failure(qualifier, result, what = "Template")
        "#{what} has #{result.analyzed_count} #{qualifier}#{result.analyzed_count > 0 ? ", but none match as expected" : ""}.\n#{format_failure(result.closest_results)}"
      end

      def format_failure(closest_results)
        keys = Js.object_keys(closest_results)
        return "No matches found" if keys.empty?

        [ "The #{keys.length} closest matches:", *keys.map { |key| "#{key} :: #{closest_results[key].render_mismatch}" } ].join("\n")
      end

      # default signal for all logicalIds is '*'
      def filter_logical_id(section, logical_id)
        return {} unless section.is_a?(Hash)
        return section if logical_id == "*"

        section.select { |key, _value| key == logical_id }
      end

      def each_entry_in_section(section)
        Js.object_keys(section || {}).each { |logical_id| yield logical_id, section[logical_id] }
      end

      def left_pad(value, indent = 2)
        pad = " " * indent
        pad + value.split("\n", -1).join("\n#{pad}")
      end
    end
  end
end
