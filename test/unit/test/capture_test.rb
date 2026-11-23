# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/test"

# This tool's own tests of RubyCdk::Test::Capture: what the CDK's own
# capture.test.ts (under test/cdk/assertions) leaves.
class TestKitCaptureTest < Minitest::Test
  # RubyCdk::Test, by a short name.
  T = RubyCdk::Test

  def test_a_capture_is_a_matcher_named_capture
    capture = T::Capture.new

    assert T::Matcher.matcher?(capture)
    assert_equal "Capture", capture.name
    assert_equal false, capture.next
  end

  def test_as_boolean
    capture = T::Capture.new
    matcher = T.object_equals("foo" => capture)

    matcher.test("foo" => true).finished
    matcher.test("foo" => "bar").finished

    assert_equal true, capture.as_boolean
    assert_equal true, capture.next
    assert_thrown(/expected to be boolean but found string/) { capture.as_boolean }
  end

  def test_every_as_reports_the_type_it_found_with_the_value
    checks = [
      [ 5, :as_string, "string but found number. Value is 5" ],
      [ "x", :as_number, "number but found string. Value is \"x\"" ],
      [ 5, :as_boolean, "boolean but found number. Value is 5" ],
      [ { "a" => 1 }, :as_array, "array but found object. Value is {\n  \"a\": 1\n}" ],
      [ [ 1 ], :as_object, "object but found array. Value is [\n  1\n]" ]
    ]
    checks.each do |value, method, expected|
      capture = T::Capture.new
      T.object_equals("foo" => capture).test("foo" => value).finished

      error = assert_thrown(/\ACaptured value is expected to be #{Regexp.escape(expected)}\z/) { capture.public_send(method) }

      assert_equal "RubyCdk::Test::AssertionError", error.class.name
    end
  end

  def test_next_stops_at_the_last_capture
    capture = T::Capture.new
    matcher = T.object_equals("foo" => capture)

    matcher.test("foo" => 1).finished
    matcher.test("foo" => 2).finished

    assert_equal true, capture.next
    assert_equal false, capture.next
    assert_equal 2, capture.as_number
    assert_equal false, capture.next
  end

  def test_a_literal_pattern_captures_only_what_is_like_it
    capture = T::Capture.new("bar" => "baz")
    matcher = T.object_like("foo" => capture)

    matcher.test("foo" => { "fred" => "waldo" }).finished
    assert_thrown(/No value captured/) { capture.as_object }

    matcher.test("foo" => { "bar" => "baz", "fred" => "waldo" }).finished
    assert_equal({ "bar" => "baz", "fred" => "waldo" }, capture.as_object)
  end

  def test_an_explicit_undefined_pattern_is_no_pattern
    capture = T::Capture.new(T::UNDEFINED)
    T.object_equals("foo" => capture).test("foo" => 5).finished

    assert_equal 5, capture.as_number
  end

  def test_a_capture_of_undefined_is_refused_as_one_of_null
    for_undefined = T::Capture.new
    result = T.object_equals("foo" => for_undefined).test("foo" => T::UNDEFINED)

    assert_equal "Can only capture non-nullish values. Found undefined at /foo (using Capture matcher)", result.to_human_strings.first
  end

  def test_a_capture_records_a_value_that_is_then_read
    capture = T::Capture.new
    result = capture.test("x")

    assert_nil result.record_capture(capture: capture, value: "y")
    result.finished

    assert_equal "x", capture.as_string
    assert_equal true, capture.next
    assert_equal "y", capture.as_string
  end

  private

  # The block throws, and the message of what it throws matches the pattern.
  def assert_thrown(pattern)
    error = assert_raises(T::AssertionError, StandardError) { yield }
    assert_match pattern, error.message
    error
  end
end
