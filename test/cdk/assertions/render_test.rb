# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/test/render.test.ts
#           (the expected output: packages/aws-cdk-lib/assertions/test/__snapshots__/render.test.ts.snap)
#           (the code it tests: packages/aws-cdk-lib/matching/lib/matcher.ts, renderMismatch())
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#
#   Cases: 11 in the original. 11 ported, 0 not ported, 0 failing.
#
#   Changed, with nothing else in a scenario, an input or an outcome:
#   - The original compares each rendering with a jest snapshot, which lives in
#     the committed .snap file next to it. Minitest has no snapshots, so the value
#     of each snapshot is written here, as the lines it is made of.
#   - Match.x is T.x, T being RubyCdk::Test, in snake_case. A rendering names the
#     matcher by the name it has here, so three snapshots are changed where they
#     name one: arrayWith is array_with.
#   - JSON.stringify of the target of the "Encodedjson matcher" case is the same
#     JSON string written by hand.

require "test_helper"
require "ruby_cdk/test"

# Snapshot tests to assert that the rendering styles of the deep mismatch rendering
# make sense
class CdkAssertionsRenderTest < Minitest::Test
  # RubyCdk::Test, by a short name.
  T = RubyCdk::Test

  # Match.objectLike with mismatched string value
  def test_match_object_like_with_mismatched_string_value
    target = {
      "Value" => "Balue",
      "Other" => "Other",
    }
    matcher = T.object_like({
      "Value" => "Value",
    })

    assert_rendered [
      "",
      "{",
      "  \"Other\": \"Other\",",
      "!! Expected Value but received Balue",
      "  \"Value\": \"Balue\"",
      "}"
    ], "", matcher.test(target)
  end

  # Deep Match.objectLike with mismatched string value
  def test_deep_match_object_like_with_mismatched_string_value
    target = {
      "Deep" => {
        "Value" => "Balue",
        "Other" => "Other",
      },
    }
    matcher = T.object_like({
      "Deep" => {
        "Value" => "Value",
      },
    })

    assert_rendered [
      "",
      "{",
      "  \"Deep\": {",
      "    \"Other\": \"Other\",",
      "!!   Expected Value but received Balue",
      "    \"Value\": \"Balue\"",
      "  }",
      "}"
    ], "", matcher.test(target)
  end

  # Match.objectEquals with unexpected key
  def test_match_object_equals_with_unexpected_key
    target = {
      "Value" => "Value",
      "Other" => "Other",
    }
    matcher = T.object_equals({
      "Value" => "Value",
    })

    assert_rendered [
      "",
      "{",
      "!! Unexpected key Other",
      "  \"Other\": \"Other\",",
      "  \"Value\": \"Value\"",
      "}"
    ], "", matcher.test(target)
  end

  # Match.objectEquals with missing key
  def test_match_object_equals_with_missing_key
    target = {}
    matcher = T.object_equals({
      "Value" => "Value",
    })

    assert_rendered [
      "",
      "{",
      "!! Missing key 'Value'",
      "  \"Value\": undefined",
      "}"
    ], "", matcher.test(target)
  end

  # Match.objectLike looking for absent key
  def test_match_object_like_looking_for_absent_key
    target = {
      "Value" => "Value",
    }
    matcher = T.object_equals({
      "Value" => T.absent,
    })

    assert_rendered [
      "",
      "{",
      "!! Received Value, but key should be absent",
      "  \"Value\": \"Value\"",
      "}"
    ], "", matcher.test(target)
  end

  # Abridged rendering of uninteresting keys (showing Other)
  def test_abridged_rendering_of_uninteresting_keys_showing_other
    target = {
      "Other" => { "OneKey" => "Visible" },
      "Value" => "Value",
    }
    matcher = T.object_like({
      "Value" => "Balue",
    })

    assert_rendered [
      "",
      "{",
      "  \"Other\": { \"OneKey\": \"Visible\" },",
      "!! Expected Balue but received Value",
      "  \"Value\": \"Value\"",
      "}"
    ], "", matcher.test(target)
  end

  # Abridged rendering of uninteresting keys (hiding Other)
  def test_abridged_rendering_of_uninteresting_keys_hiding_other
    target = {
      "Other" => { "OneKey" => "Visible", "TooMany" => "Keys" },
      "Value" => "Value",
    }
    matcher = T.object_like({
      "Value" => "Balue",
    })

    assert_rendered [
      "",
      "{",
      "  \"Other\": { ... },",
      "!! Expected Balue but received Value",
      "  \"Value\": \"Value\"",
      "}"
    ], "", matcher.test(target)
  end

  # Encodedjson matcher
  def test_encoded_json_matcher
    target = {
      "Json" => JSON.generate({
        "Value" => "Value",
      }),
    }
    matcher = T.object_like({
      "Json" => T.serialized_json({
        "Value" => "Balue",
      }),
    })

    assert_rendered [
      "",
      "{",
      "!! Encoded JSON value does not match",
      "  \"Json\": \"{\\\"Value\\\":\\\"Value\\\"}\" <*> {",
      "!!   Expected Balue but received Value",
      "    \"Value\": \"Value\"",
      "  }",
      "}"
    ], "", matcher.test(target)
  end

  # ArrayWith matcher
  # Most entries should be collapsed but at least one should for a deep comparison
  def test_array_with_matcher
    target = {
      "List" => [
        { "Value" => "1", "MakeItBig" => true },
        { "Value" => "2", "MakeItBig" => true },
        { "Value" => "3", "MakeItBig" => true },
        { "Value" => "4", "MakeItBig" => true },
      ],
    }
    matcher = T.object_like({
      "List" => T.array_with([
        T.object_like({ "Value" => "5" }),
      ]),
    })

    assert_rendered [
      "Most entries should be collapsed but at least one should for a deep comparison",
      "{",
      "  \"List\": [",
      "!!   Could not match array_with pattern 0. This is the closest match",
      "    {",
      "      \"MakeItBig\": true,",
      "!!     Expected 5 but received 1",
      "      \"Value\": \"1\"",
      "    },",
      "    { ... },",
      "    { ... },",
      "    { ... }",
      "  ]",
      "}"
    ], "Most entries should be collapsed but at least one should for a deep comparison", matcher.test(target)
  end

  # ArrayWith partial match
  # Most entries should be collapsed but at least one should for a deep comparison, and should show a place for previous matches
  def test_array_with_partial_match
    target = {
      "List" => [
        { "Value" => "1", "MakeItBig" => true },
        { "Value" => "2", "MakeItBig" => true },
        { "Value" => "3", "MakeItBig" => true },
        { "Value" => "4", "MakeItBig" => true },
      ],
    }
    matcher = T.object_like({
      "List" => T.array_with([
        T.object_like({ "Value" => "2" }),
        T.object_like({ "Value" => "5" }),
      ]),
    })
    note = "Most entries should be collapsed but at least one should for a deep comparison, and should show a place for previous matches"

    assert_rendered [
      note,
      "{",
      "  \"List\": [",
      "    { ... },",
      "!!   array_with pattern 0 matched here",
      "    {",
      "      \"MakeItBig\": true,",
      "      \"Value\": \"2\"",
      "    },",
      "!!   Could not match array_with pattern 1. This is the closest match",
      "    {",
      "      \"MakeItBig\": true,",
      "!!     Expected 5 but received 3",
      "      \"Value\": \"3\"",
      "    },",
      "    { ... }",
      "  ]",
      "}"
    ], note, matcher.test(target)
  end

  # ArrayWith out-of-order match
  def test_array_with_out_of_order_match
    target = [ 5, 3 ]
    matcher = T.array_with([ 3, 5 ])

    assert_rendered [
      "",
      "[",
      "  5,",
      "!! array_with pattern 0 matched here",
      "  3",
      "!! Could not match array_with pattern 1. No more elements to try",
      "  ",
      "]"
    ], "", matcher.test(target)
  end

  private

  # jest's expect(`${note}\n${result.renderMismatch()}`).toMatchSnapshot(): the
  # note, a newline, the rendering, equal to the lines of the committed snapshot.
  def assert_rendered(snapshot_lines, note, result)
    assert_equal snapshot_lines.join("\n"), "#{note}\n#{result.render_mismatch}"
  end
end
