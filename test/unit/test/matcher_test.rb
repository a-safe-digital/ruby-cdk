# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/test"

# This tool's own tests of the matcher engine of RubyCdk::Test: the paths the
# CDK's own tests (under test/cdk/assertions) leave. Every case here states what
# the CDK's engine does in JavaScript, read from its source at the commit named
# in the headers of lib/ruby_cdk/test.
class TestKitMatcherTest < Minitest::Test
  # RubyCdk::Test, by a short name.
  T = RubyCdk::Test

  # --- MatchResult

  def test_push_records_a_failure_as_record_failure_does
    result = T::MatchResult.new(1)

    assert_same result, result.push(T.exact(1), [ "a" ], "first")

    assert_equal 1, result.fail_count
    assert_equal 1, result.fail_cost
    assert_equal [ "first at /a (using exact matcher)" ], result.to_human_strings
  end

  def test_the_cost_of_a_failure_is_1_unless_one_is_given
    result = T::MatchResult.new(1)
    result.record_failure(matcher: T.exact(1), path: [], message: "counted", cost: nil)
    result.record_failure(matcher: T.exact(1), path: [], message: "information", cost: 0)
    result.record_failure(matcher: T.exact(1), path: [ "x" ], message: "dear", cost: 7)

    assert_equal 3, result.fail_count
    assert_equal 8, result.fail_cost
  end

  def test_a_result_that_succeeded_renders_as_a_match
    assert_equal "<match>", T.exact(1).test(1).render_mismatch
  end

  def test_failures_are_kept_by_path_in_the_order_they_were_recorded
    result = T::MatchResult.new({})
    result.record_failure(matcher: T.exact(1), path: [ "b" ], message: "one")
    result.record_failure(matcher: T.exact(1), path: [ "a" ], message: "two")
    result.record_failure(matcher: T.exact(1), path: [ "b" ], message: "three")

    assert_equal [ "b", "a" ], result.failures_here.keys
    # By path, in the order the paths were first seen, then in the order recorded.
    assert_equal [ "one", "three", "two" ], result.to_human_strings.map { |string| string.split(" ").first }
    assert_equal({ "b" => [ "one", "three" ], "a" => [ "two" ] }, result.failures_here.transform_values { |fails| fails.map(&:message) })
  end

  def test_a_match_failure_is_a_data_with_the_fields_of_the_cdk
    failure = T::MatchFailure.new(matcher: T.exact(1), path: [], message: "m", cost: nil)

    assert_equal [ T.exact(1).name, [], "m", nil ], [ failure.matcher.name, failure.path, failure.message, failure.cost ]
    assert_equal [ :matcher, :path, :message, :cost ], T::MatchFailure.members

    capture = T::Capture.new
    assert_equal [ capture, 5 ], [ T::MatchCapture.new(capture: capture, value: 5).capture, T::MatchCapture.new(capture: capture, value: 5).value ]
    assert_equal [ :capture, :value ], T::MatchCapture.members
  end

  def test_record_capture_hands_nothing_over_before_finished
    capture = T::Capture.new
    result = T::MatchResult.new(5)
    result.record_capture(capture: capture, value: 5)

    assert_thrown(/No value captured/) { capture.as_number }
    result.finished
    assert_equal 5, capture.as_number
  end

  def test_finished_is_idempotent_and_gives_the_result_back
    capture = T::Capture.new
    result = T::MatchResult.new(5)
    result.record_capture(capture: capture, value: 5)

    assert_same result, result.finished
    assert_same result, result.finished
    assert_equal 5, capture.as_number
    assert_equal false, capture.next
  end

  def test_compose_keeps_the_failures_of_an_inner_result_under_its_id
    outer = T::MatchResult.new({ "a" => 1 })
    inner = T.exact(2).test(1)
    outer.compose("a", inner)

    assert_predicate outer, :has_failed?
    assert_equal false, outer.is_success?
    assert_equal 1, outer.fail_count
    assert_equal 1, outer.fail_cost
    assert_same inner, outer.inner_match_failures["a"]
    assert_equal [ "Expected 2 but received 1 at /a (using exact matcher)" ], outer.to_human_strings
  end

  # --- where JavaScript itself throws

  def test_a_null_in_a_pattern_is_refused_as_javascript_refuses_it
    assert_thrown(/Cannot convert undefined or null to object/) { T.object_like("a" => nil).test("a" => nil) }
    assert_thrown(/Cannot convert undefined or null to object/) { T.exact(nil).test({}) }
    assert_equal [ "Expected type object but received string (using exact matcher)" ], T.exact(nil).test("x").to_human_strings
  end

  def test_a_null_target_is_refused_as_javascript_refuses_it_when_the_pattern_asks_for_a_key
    assert_thrown(/Cannot use 'in' operator to search for 'a' in null/) { T.object_like("a" => 1).test(nil) }
    assert_thrown(/Cannot convert undefined or null to object/) { T.object_equals({ "a" => 1 }).test(nil) }
    assert_thrown(/Cannot convert undefined or null to object/) { T.object_equals({}).test(nil) }
  end

  def test_an_empty_partial_pattern_matches_a_null_target_as_it_does_there
    assert_equal false, T.object_like({}).test(nil).has_failed?
  end

  def test_undefined_is_not_null
    assert_equal false, T.absent.test(T::UNDEFINED).has_failed?
    assert_equal true, T.absent.test(nil).has_failed?
    assert_equal true, T.any_value.test(T::UNDEFINED).has_failed?
    assert_equal "undefined", T::UNDEFINED.to_s
    assert_equal "undefined", T::UNDEFINED.inspect
    assert_predicate T::UNDEFINED, :frozen?
  end

  # --- numbers, as JavaScript has them

  def test_a_whole_float_and_an_integer_are_the_same_number
    assert_equal false, T.exact(1).test(1.0).has_failed?
    assert_equal false, T.exact(1.0).test(1).has_failed?
    assert_equal true, T.exact(1).test(1.5).has_failed?
    assert_equal "Expected 2.5 but received 3 at /a (using exact matcher)", T.exact({ "a" => 2.5 }).test({ "a" => 3 }).to_human_strings.first
  end

  def test_a_string_is_never_a_number
    assert_equal "Expected type number but received string (using exact matcher)", T.exact(1).test("1").to_human_strings.first
  end

  # --- stringLikeRegexp

  def test_string_like_regexp_reads_a_target_that_is_not_a_string_as_a_string
    strings = T.string_like_regexp("\\d").test(5).to_human_strings

    assert_equal [ "Expected a string, but got 'number' (using string_like_regexp matcher)" ], strings
  end

  def test_string_like_regexp_anchors_at_line_ends_and_stops_at_a_newline
    assert_equal false, T.string_like_regexp("^b$").test("a\nb\nc").has_failed?
    assert_equal true, T.string_like_regexp("a.c").test("a\nc").has_failed?
  end

  def test_string_like_regexp_needs_a_pattern_javascript_compiles_too
    assert_raises(RegexpError) { T.string_like_regexp("(").test("x") }
  end

  # --- serializedJson

  def test_serialized_json_reads_any_json_text_not_only_an_object
    assert_equal false, T.serialized_json(1).test("1").has_failed?
    assert_equal false, T.serialized_json([ 1 ]).test("[1]").has_failed?
    assert_equal true, T.serialized_json(1).test("2").has_failed?
  end

  def test_serialized_json_is_not_stopped_by_deep_nesting
    json = "[" * 200 + "1" + "]" * 200

    assert_equal false, T.serialized_json(JSON.parse(json, max_nesting: false)).test(json).has_failed?
  end

  def test_serialized_json_matches_a_nested_literal_exactly
    # The literal inside a serialized_json pattern is compiled as an exact match,
    # as the CDK's is (partialObjects false): the parsed JSON may not carry keys
    # the pattern does not name.
    result = T.serialized_json({ "Foo" => { "Bar" => 1 } }).test('{"Foo":{"Bar":1,"Baz":2}}')

    assert_equal true, result.has_failed?
    assert_includes result.to_human_strings.join("\n"), "Unexpected key Baz at /Foo/Baz"
  end

  # --- arrayWith

  def test_an_empty_array_with_matches_any_array
    assert_equal false, T.array_with([]).test([ 1 ]).has_failed?
    assert_equal true, T.array_with([]).test(1).has_failed?
  end

  def test_array_with_reports_the_element_that_did_not_match
    result = T.array_with([ 1 ]).test([ 2, 3, 4 ])

    assert_equal [ "Could not match array_with pattern 0. This is the closest match at /0 (using array_with matcher)",
                   "Expected 1 but received 2 at /0 (using array_with matcher)" ], result.to_human_strings
    assert_equal 1, result.fail_cost
  end

  def test_array_with_says_when_there_was_nothing_left_to_try
    result = T.array_with([ 1, 2 ]).test([ 1 ])

    # Its own failures come first, then the ones composed under the elements.
    assert_equal [ "Could not match array_with pattern 1. No more elements to try at /1 (using array_with matcher)",
                   "array_with pattern 0 matched here at /0 (using array_with matcher)" ], result.to_human_strings
    assert_equal 1, result.fail_cost
  end

  def test_array_with_reports_the_closest_of_several_elements
    result = T.array_with([ T.object_like({ "a" => 1, "b" => 1 }) ]).test([ { "a" => 0, "b" => 0 }, { "a" => 0, "b" => 1 } ])

    assert_equal [ "Could not match array_with pattern 0. This is the closest match at /1 (using array_with matcher)",
                   "Expected 1 but received 0 at /1/a (using object_like matcher)" ], result.to_human_strings
    assert_equal 1, result.fail_cost
  end

  # --- the three closest, by cost

  def test_the_closest_matches_are_taken_by_cost_first
    template = T.from_json({ "Parameters" => {
      "Far" => { "Type" => "String", "Default" => "x" },
      "Near" => { "Type" => "CommaDelimitedList" },
      "Middle" => { "Type" => "Number" }
    } })

    error = assert_raises(T::AssertionError) { template.has_parameter("*", { "Type" => "CommaDelimitedList", "Default" => "y" }) }

    # Near fails on one key (cost 1); Far and Middle fail on two (cost 2), and
    # Far comes first among equals.
    assert_match(/The 3 closest matches:\nNear :: .*Far :: .*Middle :: /m, error.message)
  end

  private

  # The block throws, and the message of what it throws matches the pattern.
  def assert_thrown(pattern)
    error = assert_raises(T::AssertionError, StandardError) { yield }
    assert_match pattern, error.message
    error
  end
end
