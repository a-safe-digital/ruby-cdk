# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/test/match.test.ts
#           (the code it tests: packages/aws-cdk-lib/matching/lib/match.ts and matcher.ts)
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#
#   Cases: 35 in the original. 35 ported, 0 not ported, 0 failing.
#
#   Changed, with nothing else in a scenario, an input or an outcome:
#   - Match.x is T.x, T being RubyCdk::Test, in snake_case. `not` is `not_`,
#     because `not` is a Ruby keyword.
#   - A message names the matcher by the name it has here, so the expected text
#     of a message is changed where it names one: arrayWith is array_with,
#     anyValue is any_value.
#   - JavaScript's undefined, which several cases pass on purpose, is
#     T::UNDEFINED. nil is its null. The two behave differently in the engine.
#   - jest's expect(fn).toThrow(pattern) is assert_thrown, defined below.
#   - The file's own expectPass and expectFailure are kept as they are.

require "test_helper"
require "ruby_cdk/test"

class CdkAssertionsMatchTest < Minitest::Test
  # RubyCdk::Test, by a short name.
  T = RubyCdk::Test

  # Matchers > exactly() > simple literals
  def test_exactly_simple_literals
    matcher = T.exact("foo")
    expect_pass(matcher, "foo")
    expect_failure(matcher, "bar", [ /Expected foo but received bar/ ])
    expect_failure(matcher, 5, [ /Expected type string but received number/ ])

    matcher = T.exact(3)
    expect_pass(matcher, 3)
    expect_failure(matcher, 5, [ /Expected 3 but received 5/ ])
    expect_failure(matcher, "foo", [ /Expected type number but received string/ ])

    matcher = T.exact(true)
    expect_pass(matcher, true)
    expect_failure(matcher, false, [ /Expected true but received false/ ])
    expect_failure(matcher, "foo", [ /Expected type boolean but received string/ ])
  end

  # Matchers > exactly() > arrays
  def test_exactly_arrays
    matcher = T.exact([ 4 ])
    expect_pass(matcher, [ 4 ])
    expect_failure(matcher, [ 4, 5 ], [ /Too many elements in array/ ])
    expect_failure(matcher, "foo", [ /Expected type array but received string/ ])

    matcher = T.exact([ "foo", 3 ])
    expect_pass(matcher, [ "foo", 3 ])
    expect_failure(matcher, [ "bar", 3 ], [ %r{Expected foo but received bar at /0} ])
    expect_failure(matcher, [ "foo", 5 ], [ %r{Expected 3 but received 5 at /1} ])

    matcher = T.exact([ { "foo" => "bar", "baz" => "qux" }, { "waldo" => "fred", "wobble" => "flob" } ])
    expect_pass(matcher, [ { "foo" => "bar", "baz" => "qux" }, { "waldo" => "fred", "wobble" => "flob" } ])
    expect_failure(matcher, [ { "foo" => "bar", "baz" => "qux" } ], [ /Not enough elements in array/ ])
    expect_failure(matcher, [ { "foo" => "bar", "baz" => "qux" }, { "waldo" => "flob", "wobble" => "fred" } ], [
      "Expected fred but received flob at /1/waldo",
      "Expected flob but received fred at /1/wobble",
    ])
    expect_failure(matcher, [ { "foo" => "bar", "baz" => "qux" }, { "waldo" => "fred" } ], [ %r{Missing key.*at /1/wobble} ])
  end

  # Matchers > exactly() > objects
  def test_exactly_objects
    matcher = T.exact({ "foo" => "bar" })
    expect_pass(matcher, { "foo" => "bar" })
    expect_failure(matcher, 5, [ /Expected type object but received number/ ])
    expect_failure(matcher, [ "3", 5 ], [ /Expected type object but received array/ ])
    expect_failure(matcher, { "baz" => "qux" }, [
      "Unexpected key baz at /baz",
      /Missing key.*at \/foo/,
    ])

    matcher = T.exact({ "foo" => "bar", "baz" => 5 })
    expect_failure(matcher, { "foo" => "bar", "baz" => "5" }, [ /Expected type number but received string at \/baz/ ])
    expect_failure(matcher, { "foo" => "bar", "baz" => 5, "qux" => 7 }, [ /Unexpected key qux at \/qux/ ])

    matcher = T.exact({ "foo" => [ 2, 3 ], "bar" => "baz" })
    expect_pass(matcher, { "foo" => [ 2, 3 ], "bar" => "baz" })
    expect_failure(matcher, {}, [
      /Missing key.*at \/foo/,
      /Missing key.*at \/bar/,
    ])
    expect_failure(matcher, { "bar" => [ 2, 3 ], "foo" => "baz" }, [
      "Expected type array but received string at /foo",
      "Expected type string but received array at /bar",
    ])
    expect_failure(matcher, { "foo" => [ 3, 5 ], "bar" => "baz" }, [
      "Expected 2 but received 3 at /foo/0",
      "Expected 3 but received 5 at /foo/1",
    ])
  end

  # Matchers > exactly() > nesting
  def test_exactly_nesting
    assert_thrown(/cannot directly contain another matcher/) { T.exact(T.array_with([ "foo" ])) }
  end

  # Matchers > exactly() > absent
  def test_exactly_absent
    assert_thrown(/cannot directly contain another matcher/) { T.exact(T.absent) }
  end

  # Matchers > arrayWith() > subset match
  def test_array_with_subset_match
    matcher = T.array_with([])
    expect_pass(matcher, [])
    expect_pass(matcher, [ 3 ])

    matcher = T.array_with([ 3 ])
    expect_pass(matcher, [ 3 ])
    expect_pass(matcher, [ 3, 5 ])
    expect_pass(matcher, [ 1, 3, 5 ])
    expect_failure(matcher, [ 5 ], [ /Could not match array_with pattern 0/ ])

    matcher = T.array_with([ 5, false ])
    expect_pass(matcher, [ 5, false, "foo" ])
    expect_pass(matcher, [ 5, "foo", false ])
    expect_failure(matcher, [ 5, "foo" ], [ /Could not match array_with pattern 1/ ])

    matcher = T.array_with([ { "foo" => "bar" } ])
    expect_pass(matcher, [ { "fred" => "waldo" }, { "foo" => "bar" }, { "baz" => "qux" } ])
    expect_pass(matcher, [ { "foo" => "bar" } ])
    expect_failure(matcher, [ { "foo" => "baz" } ], [ /Could not match array_with pattern 0/ ])
    expect_failure(matcher, [ { "baz" => "qux" } ], [ /Could not match array_with pattern 0/ ])
  end

  # Matchers > arrayWith() > not array
  def test_array_with_not_array
    matcher = T.array_with([ 3 ])
    expect_failure(matcher, 3, [ /Expected type array but received number/ ])
    expect_failure(matcher, { "val" => 3 }, [ /Expected type array but received object/ ])
  end

  # Matchers > arrayWith() > out of order
  def test_array_with_out_of_order
    matcher = T.array_with([ 3, 5 ])
    expect_failure(matcher, [ 5, 3 ], [ /Could not match array_with pattern 1/ ])
  end

  # Matchers > arrayWith() > nested with ObjectLike
  def test_array_with_nested_with_object_like
    matcher = T.array_with([ T.object_like({ "foo" => "bar" }) ])
    expect_pass(matcher, [ { "baz" => "qux" }, { "foo" => "bar" } ])
    expect_pass(matcher, [ { "baz" => "qux" }, { "foo" => "bar", "fred" => "waldo" } ])
    expect_failure(matcher, [ { "foo" => "baz", "fred" => "waldo" } ], [ /Could not match array_with pattern 0/ ])
  end

  # Matchers > arrayWith() > incompatible with absent
  def test_array_with_incompatible_with_absent
    matcher = T.array_with([ "foo", T.absent ])
    assert_thrown(/absent\(\) cannot be nested within array_with\(\)/) { matcher.test([ "foo", "bar" ]) }
  end

  # Matchers > arrayWith() > incompatible with anyValue
  def test_array_with_incompatible_with_any_value
    matcher = T.array_with([ "foo", T.any_value ])
    assert_thrown(/any_value\(\) cannot be nested within array_with\(\)/) { matcher.test([ "foo", "bar" ]) }
  end

  # Matchers > arrayEquals > exact match
  def test_array_equals_exact_match
    matcher = T.array_equals([ 5, false ])
    expect_pass(matcher, [ 5, false ])
    expect_failure(matcher, [ 5, "foo", false ], [ /Too many elements in array/ ])
    expect_failure(matcher, [ 5, "foo" ], [ /Expected type boolean but received string at \/1/ ])
  end

  # Matchers > objectLike() > basic
  def test_object_like_basic
    matcher = T.object_like({ "foo" => "bar" })
    expect_pass(matcher, { "foo" => "bar" })
    expect_failure(matcher, { "foo" => "baz" }, [ /Expected bar but received baz at \/foo/ ])
    expect_failure(matcher, { "foo" => [ "bar" ] }, [ /Expected type string but received array at \/foo/ ])
    expect_failure(matcher, { "bar" => "foo" }, [ /Missing key.*at \/foo/ ])
    expect_pass(matcher, { "foo" => "bar", "baz" => "qux" })
  end

  # Matchers > objectLike() > not an object
  def test_object_like_not_an_object
    matcher = T.object_like({ "foo" => "bar" })
    expect_failure(matcher, [ "foo", "bar" ], [ /Expected type object but received array/ ])
    expect_failure(matcher, "foo", [ /Expected type object but received string/ ])

    matcher = T.object_like({ "foo" => T.object_like({ "baz" => "qux" }) })
    expect_failure(matcher, { "foo" => "baz" }, [ /Expected type object but received string at \/foo/ ])
  end

  # Matchers > objectLike() > partial
  def test_object_like_partial
    matcher = T.object_like({ "foo" => "bar" })
    expect_pass(matcher, { "foo" => "bar", "baz" => { "fred" => "waldo" } })

    matcher = T.object_like({ "baz" => { "fred" => "waldo" } })
    expect_pass(matcher, { "foo" => "bar", "baz" => { "fred" => "waldo", "wobble" => "flob" } })
  end

  # Matchers > objectLike() > ArrayMatch nested inside ObjectMatch
  def test_object_like_array_match_nested_inside_object_match
    matcher = T.object_like({
      "foo" => T.array_with([ "bar" ]),
    })
    expect_pass(matcher, { "foo" => [ "bar", "baz" ], "fred" => "waldo" })
    expect_failure(matcher, { "foo" => [ "baz" ], "fred" => "waldo" }, [ /Could not match array_with pattern 0/ ])
  end

  # Matchers > objectLike() > Partiality is maintained throughout arrays
  def test_object_like_partiality_is_maintained_throughout_arrays
    # Before this fix:
    #
    #   - objectLike({ x: { LITERAL }) ==> LITERAL would be matched partially as well
    #   - objectLike({ xs: [ { LITERAL } ] }) ==> but here LITERAL would be matched fully
    #
    # That passing through an array resets the partial matching to full is a
    # surprising inconsistency.
    #
    matcher = T.object_like({
      "foo" => [ { "bar" => "bar" } ],
    })
    expect_pass(matcher, { "foo" => [ { "bar" => "bar" } ] }) # Trivially true
    expect_pass(matcher, { "boo" => "boo", "foo" => [ { "bar" => "bar" } ] }) # Additional members at top level okay
    expect_pass(matcher, { "foo" => [ { "bar" => "bar", "boo" => "boo" } ] }) # Additional members at inner level okay
  end

  # Matchers > objectLike() > absent
  def test_object_like_absent
    matcher = T.object_like({ "foo" => T.absent })
    expect_pass(matcher, { "bar" => "baz" })
    expect_failure(matcher, { "foo" => "baz" }, [ /key should be absent at \/foo/ ])
  end

  # Matchers > objectEquals() > exact match
  def test_object_equals_exact_match
    matcher = T.object_equals({ "foo" => "bar" })
    expect_pass(matcher, { "foo" => "bar" })
    expect_failure(matcher, { "foo" => "bar", "baz" => "qux" }, [ /Unexpected key baz at \/baz/ ])
  end

  # Matchers > not() > literal
  def test_not_literal
    matcher = T.not_("foo")
    expect_pass(matcher, "bar")
    expect_pass(matcher, 3)

    expect_failure(matcher, "foo", [ 'Found unexpected match: "foo"' ])
  end

  # Matchers > not() > object
  def test_not_object
    matcher = T.not_({ "foo" => "bar" })
    expect_pass(matcher, "bar")
    expect_pass(matcher, 3)
    expect_pass(matcher, { "foo" => "baz" })
    expect_pass(matcher, { "bar" => "foo" })

    msg = <<~MSG.chomp
      Found unexpected match: {
        "foo": "bar"
      }
    MSG
    expect_failure(matcher, { "foo" => "bar" }, [ msg ])
  end

  # Matchers > not() > array
  def test_not_array
    matcher = T.not_([ "foo", "bar" ])
    expect_pass(matcher, "foo")
    expect_pass(matcher, [])
    expect_pass(matcher, [ "bar" ])
    expect_pass(matcher, [ "foo", 3 ])

    msg = <<~MSG.chomp
      Found unexpected match: [
        "foo",
        "bar"
      ]
    MSG
    expect_failure(matcher, [ "foo", "bar" ], [ msg ])
  end

  # Matchers > not() > as a nested matcher
  def test_not_as_a_nested_matcher
    matcher = T.exact({
      "foo" => { "bar" => T.not_([ 1, 2 ]) },
    })

    expect_pass(matcher, {
      "foo" => { "bar" => [ 1 ] },
    })
    expect_pass(matcher, {
      "foo" => { "bar" => [ "baz" ] },
    })

    msg = <<~MSG.chomp
      Found unexpected match: [
        1,
        2
      ] at /foo/bar
    MSG
    expect_failure(matcher, {
      "foo" => { "bar" => [ 1, 2 ] },
    }, [ msg ])
  end

  # Matchers > not() > with nested matcher
  def test_not_with_nested_matcher
    matcher = T.not_({
      "foo" => { "bar" => T.array_with([ 1 ]) },
    })

    expect_pass(matcher, {
      "foo" => { "bar" => [ 2 ] },
    })
    expect_pass(matcher, "foo")

    msg = <<~MSG.chomp
      Found unexpected match: {
        "foo": {
          "bar": [
            1,
            2
          ]
        }
      }
    MSG
    expect_failure(matcher, {
      "foo" => { "bar" => [ 1, 2 ] },
    }, [ msg ])
  end

  # Matchers > anyValue() > simple
  def test_any_value_simple
    matcher = T.any_value
    expect_pass(matcher, "foo")
    expect_pass(matcher, 5)
    expect_pass(matcher, false)
    expect_pass(matcher, [])
    expect_pass(matcher, {})

    expect_failure(matcher, nil, [ "Expected a value but found none" ])
    expect_failure(matcher, T::UNDEFINED, [ "Expected a value but found none" ])
  end

  # Matchers > anyValue() > nested in array
  def test_any_value_nested_in_array
    matcher = T.array_equals([ "foo", T.any_value, "bar" ])
    expect_pass(matcher, [ "foo", "baz", "bar" ])
    expect_pass(matcher, [ "foo", 3, "bar" ])

    expect_failure(matcher, [ "foo", nil, "bar" ], [ "Expected a value but found none at /1" ])
  end

  # Matchers > anyValue() > nested in object
  def test_any_value_nested_in_object
    matcher = T.object_like({ "foo" => T.any_value })
    expect_pass(matcher, { "foo" => "bar" })
    expect_pass(matcher, { "foo" => [ 1, 2 ] })

    expect_failure(matcher, { "foo" => nil }, [ "Expected a value but found none at /foo" ])
    expect_failure(matcher, {}, [ /Missing key.*at \/foo/ ])
  end

  # Matchers > serializedJson() > all types
  def test_serialized_json_all_types
    matcher = T.serialized_json({ "Foo" => "Bar", "Baz" => 3, "Boo" => true, "Fred" => [ 1, 2 ] })
    expect_pass(matcher, '{ "Foo": "Bar", "Baz": 3, "Boo": true, "Fred": [1, 2] }')
  end

  # Matchers > serializedJson() > simple match
  def test_serialized_json_simple_match
    matcher = T.serialized_json({ "Foo" => "Bar" })
    expect_pass(matcher, '{ "Foo": "Bar" }')

    expect_failure(matcher, '{ "Foo": "Baz" }', [ /Encoded JSON value does not match/, "Expected Bar but received Baz at /Foo" ])
    expect_failure(matcher, '{ "Foo": 4 }', [ /Encoded JSON value does not match/, "Expected type string but received number at /Foo" ])
    expect_failure(matcher, '{ "Bar": "Baz" }', [
      /Encoded JSON value does not match/,
      "Unexpected key Bar at /Bar",
      /Missing key.*at \/Foo/,
    ])
  end

  # Matchers > serializedJson() > nested matcher
  def test_serialized_json_nested_matcher
    matcher = T.serialized_json(T.object_like({
      "Foo" => T.array_with([ "Bar" ]),
    }))

    expect_pass(matcher, '{ "Foo": ["Bar"] }')
    expect_pass(matcher, '{ "Foo": ["Bar", "Baz"] }')
    expect_pass(matcher, '{ "Foo": ["Bar", "Baz"], "Fred": "Waldo" }')

    expect_failure(matcher, '{ "Foo": ["Baz"] }', [ "Could not match array_with pattern 0" ])
    expect_failure(matcher, '{ "Bar": ["Baz"] }', [ /Missing key.*at \/Foo/ ])
  end

  # Matchers > serializedJson() > invalid json string
  def test_serialized_json_invalid_json_string
    matcher = T.serialized_json({ "Foo" => "Bar" })

    expect_failure(matcher, '{ "Foo"', [ /invalid JSON string/i ])
  end

  # Matchers > absent > simple
  def test_absent_simple
    matcher = T.absent
    expect_failure(matcher, "foo", [ "Received foo, but key should be absent" ])
    expect_pass(matcher, T::UNDEFINED)
  end

  # Matchers > absent > nested in object
  def test_absent_nested_in_object
    matcher = T.object_like({ "foo" => T.absent })
    expect_failure(matcher, { "foo" => "bar" }, [ /key should be absent at \/foo/ ])
    expect_failure(matcher, { "foo" => [ 1, 2 ] }, [ /key should be absent at \/foo/ ])
    expect_failure(matcher, { "foo" => nil }, [ /key should be absent at \/foo/ ])

    expect_pass(matcher, { "foo" => T::UNDEFINED })
    expect_pass(matcher, {})
  end

  # Matchers > stringLikeRegexp > simple
  def test_string_like_regexp_simple
    matcher = T.string_like_regexp(".*includeHeaders = true.*")
    expect_failure(matcher, "const includeHeaders = false;", [ /did not match pattern/ ])
    expect_pass(matcher, "const includeHeaders = true;")
  end

  # Matchers > stringLikeRegexp > nested in object
  def test_string_like_regexp_nested_in_object
    matcher = T.object_like({ "foo" => T.string_like_regexp(".*includeHeaders = true.*") })
    expect_failure(matcher, { "foo" => "const includeHeaders = false;" }, [ /did not match pattern/ ])
    expect_pass(matcher, { "foo" => "const includeHeaders = true;" })
  end

  private

  # jest's expect(fn).toThrow(pattern): the block throws, and the message of what
  # it throws matches the pattern when one is given.
  def assert_thrown(pattern = nil)
    error = assert_raises(T::AssertionError, StandardError) { yield }
    assert_match pattern, error.message if pattern
    error
  end

  def expect_pass(matcher, target)
    result = matcher.test(target)
    raise Minitest::Assertion, result.to_human_strings.join("\n") if result.has_failed?
  end

  def expect_failure(matcher, target, expected = [])
    result = matcher.test(target)
    assert_operator result.fail_count, :>, 0
    actual = result.to_human_strings

    not_found = expected.reject do |needle|
      actual.any? { |haystack| needle.is_a?(Regexp) ? haystack.match?(needle) : haystack.include?(needle) }
    end

    assert_empty not_found, "Patterns: #{not_found.inspect}\nMissing from error:\n#{actual.join("\n")}"
  end
end
