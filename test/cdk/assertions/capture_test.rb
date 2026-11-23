# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/test/capture.test.ts
#           (the code it tests: packages/aws-cdk-lib/matching/lib/capture.ts)
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#
#   Cases: 12 in the original. 12 ported, 0 not ported, 0 failing.
#
#   Changed, with nothing else in a scenario, an input or an outcome:
#   - `new Capture()` is T::Capture.new and Match.x is T.x, T being RubyCdk::Test,
#     in snake_case.
#   - A message names the matcher by the name it has here, so where the expected
#     text of a message names one it is changed: objectLike is object_like,
#     arrayWith is array_with.
#   - jest's expect(fn).toThrow(pattern) is assert_thrown, defined below.

require "test_helper"
require "ruby_cdk/test"

class CdkAssertionsCaptureTest < Minitest::Test
  # RubyCdk::Test, by a short name.
  T = RubyCdk::Test

  # Capture > uncaptured
  def test_uncaptured
    capture = T::Capture.new
    assert_thrown(/No value captured/) { capture.as_string }
  end

  # Capture > nullish
  def test_nullish
    capture = T::Capture.new
    matcher = T.object_equals("foo" => capture)

    result = matcher.test("foo" => nil)
    assert_equal 1, result.fail_count
    assert_match(/Can only capture non-nullish values/, result.to_human_strings[0])
  end

  # Capture > no captures if not finished
  def test_no_captures_if_not_finished
    capture = T::Capture.new
    matcher = T.object_equals("foo" => capture)

    matcher.test("foo" => "bar") # Not calling finished()
    assert_thrown(/No value captured/) { capture.as_string }
  end

  # Capture > asString()
  def test_as_string
    capture = T::Capture.new
    matcher = T.object_equals("foo" => capture)

    matcher.test("foo" => "bar").finished
    matcher.test("foo" => 3).finished

    assert_equal "bar", capture.as_string
    assert_equal true, capture.next
    assert_thrown(/expected to be string but found number/) { capture.as_string }
  end

  # Capture > asNumber()
  def test_as_number
    capture = T::Capture.new
    matcher = T.object_equals("foo" => capture)

    matcher.test("foo" => 3).finished
    matcher.test("foo" => "bar").finished

    assert_equal 3, capture.as_number
    assert_equal true, capture.next
    assert_thrown(/expected to be number but found string/) { capture.as_number }
  end

  # Capture > asArray()
  def test_as_array
    capture = T::Capture.new
    matcher = T.object_equals("foo" => capture)

    matcher.test("foo" => [ "bar" ]).finished
    matcher.test("foo" => "bar").finished

    assert_equal [ "bar" ], capture.as_array
    assert_equal true, capture.next
    assert_thrown(/expected to be array but found string/) { capture.as_array }
  end

  # Capture > asObject()
  def test_as_object
    capture = T::Capture.new
    matcher = T.object_equals("foo" => capture)

    matcher.test("foo" => { "fred" => "waldo" }).finished
    matcher.test("foo" => "bar").finished

    assert_equal({ "fred" => "waldo" }, capture.as_object)
    assert_equal true, capture.next
    assert_thrown(/expected to be object but found string/) { capture.as_object }
  end

  # Capture > nested within an array
  def test_nested_within_an_array
    capture = T::Capture.new
    matcher = T.object_equals("foo" => [ "bar", capture ])

    matcher.test("foo" => [ "bar", "baz" ]).finished
    assert_equal "baz", capture.as_string
  end

  # Capture > multiple captures
  def test_multiple_captures
    capture = T::Capture.new
    matcher = T.object_equals({ "foo" => capture, "real" => true })

    matcher.test({ "foo" => 3, "real" => true }).finished
    matcher.test({ "foo" => 5, "real" => true }).finished
    matcher.test({ "foo" => 7, "real" => false }).finished

    assert_equal 3, capture.as_number
    assert_equal true, capture.next
    assert_equal 5, capture.as_number
    assert_equal false, capture.next
  end

  # Capture > nested pattern match
  def test_nested_pattern_match
    capture = T::Capture.new(T.object_like({ "bar" => "baz" }))
    matcher = T.object_like("foo" => capture)

    matcher.test({
      "foo" => {
        "bar" => "baz",
        "fred" => "waldo",
      },
    }).finished

    assert_equal({ "bar" => "baz", "fred" => "waldo" }, capture.as_object)
    assert_equal false, capture.next
  end

  # Capture > nested pattern does not match
  def test_nested_pattern_does_not_match
    capture = T::Capture.new(T.object_like({ "bar" => "baz" }))
    matcher = T.object_like("foo" => capture)

    matcher.test({
      "foo" => {
        "fred" => "waldo",
      },
    }).finished

    assert_thrown(/No value captured/) { capture.as_object }
  end

  # Capture > capture in arraywith and objectlike
  def test_capture_in_array_with_and_object_like
    capture = T::Capture.new
    matcher = T.object_like({
      "People" => T.array_with([{
        "Name" => "Alice",
        "Attributes" => [
          T.object_like({
            "Name" => "HairColor",
            "Value" => capture,
          }),
        ],
      }]),
    })

    result = matcher.test({
      "People" => [
        {
          "Name" => "Alice",
          "Attributes" => [
            { "Name" => "HairColor", "Value" => "Black" },
          ],
        },
      ],
    })

    assert_equal true, result.is_success?
    result.finished
    assert_equal "Black", capture.as_string
  end

  private

  # jest's expect(fn).toThrow(pattern): the block throws, and the message of what
  # it throws matches the pattern when one is given.
  def assert_thrown(pattern = nil)
    error = assert_raises(T::AssertionError, StandardError) { yield }
    assert_match pattern, error.message if pattern
    error
  end
end
