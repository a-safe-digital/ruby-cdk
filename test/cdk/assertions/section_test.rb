# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/test/private/section.test.ts
#           (the code it tests: packages/aws-cdk-lib/assertions/lib/private/section.ts)
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#
#   Cases: 2 in the original. 2 ported, 0 not ported, 0 failing.
#
#   Changed, with nothing else in a scenario, an input or an outcome:
#   - camelCase to snake_case: matchSection is RubyCdk::Test::Private.match_section,
#     analyzedCount is analyzed_count, closestResults is closest_results.
#   - The original returns a MatchSuccess or a MatchFailure; the port returns one
#     SectionMatch, so the `as MatchSuccess` castings of the original are gone.
#   - jest's expect(x).toEqual(y) is assert_equal y, x, and expect(x).not.toEqual(y)
#     is refute_equal y, x.

require "test_helper"
require "ruby_cdk/test"

# section > matchSection
class CdkAssertionsSectionTest < Minitest::Test
  # RubyCdk::Test, by a short name.
  T = RubyCdk::Test

  def test_match_section_success
    # GIVEN
    matcher = T.object_like({ "foo" => "bar" })
    section = {
      "Entry1" => { "foo" => "bar" },
      "Entry2" => { "foo" => "bar", "baz" => "qux" },
      "Entry3" => { "fred" => "waldo" }
    }

    # WHEN
    result = T::Private.match_section(section, matcher)

    # THEN
    assert_equal true, result.match
    assert_equal 2, result.matches.keys.length
    assert_equal({ "foo" => "bar" }, result.matches["Entry1"])
    assert_equal({ "foo" => "bar", "baz" => "qux" }, result.matches["Entry2"])
  end

  def test_match_section_failure
    # GIVEN
    matcher = T.object_like({ "foo" => "bar" })
    section = {
      "Entry1" => { "foo" => "qux" },
      "Entry3" => { "fred" => "waldo" }
    }

    # WHEN
    result = T::Private.match_section(section, matcher)

    # THEN
    assert_equal false, result.match
    assert_equal 2, result.analyzed_count

    closest_keys = result.closest_results.keys
    refute_equal [], closest_keys
    assert_equal({ "foo" => "qux" }, result.closest_results[closest_keys[0]].target)
  end
end
