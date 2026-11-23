# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/core/test/fn.test.ts, in aws/aws-cdk
#   Commit:  78649cb7cf7399204ed63f629964779eeaa8b37a (main, read on 2026-11-23)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 23 cases. Each ported one keeps its name, as a comment above
# the test, and what it expects. What changed to get there:
#
#   - This tool has no tokens. Where the origin builds an intrinsic and passes
#     its token string, the port passes the intrinsic itself, the Hash that
#     Fn.* answers. What is expected is not touched by that.
#   - The origin's property tests run fast-check. No gem is added here, so each
#     runs over fixed values that cover what its generator produced: any
#     delimiter, the empty one and non-ASCII included; non-empty strings; an
#     object with one key.
#   - The origin's `new Stack()` is `new_stack` here: a Stack of this tool
#     needs an App and an id.
#
# Not ported, with the reason:
#
#   - parse domain name from resolved url; parse domain name on token.
#     Fn.parseDomainName is not in the Fn contract (architecture §3).
#   - Fn::EachMemberIn. Fn.conditionEachMemberIn, Fn.valueOfAll and Fn.refAll are
#     not in the contract, and the last two answer list tokens.
#   - cross-stack FnJoin elements are properly resolved. It turns on the CDK's
#     automatic cross-stack reference, a token for another stack's export that
#     is named by a hash. This tool has neither tokens nor automatic
#     cross-stack references (architecture §9: nothing is generated implicitly).
#   - nested Fn::Join with list token. A list token, a list whose one element
#     resolves to something that is not a list, has no equivalent: every list
#     here is a real list.
#   - Fn.toJsonString; Fn.toJsonString with resolved value; Fn.len; Fn.len with
#     resolved value. Fn.toJsonString and Fn.len are not in the contract, and
#     their deferred form needs the AWS::LanguageExtensions transform.
#
# So 14 cases are ported and 9 are listed.

require "test_helper"
require "support/core_helpers"

class CdkFnTest < CoreHelpers::TestCase
  Fn = RubyCdk::Fn

  # describe('eager resolution for non-tokens')

  # test('Fn.select')
  def test_fn_select
    assert_equal "dude", Fn.select(2, [ "hello", "you", "dude" ])
  end

  # test('Fn.select does not short-circuit if there are tokens in the array')
  def test_fn_select_does_not_short_circuit_if_there_are_tokens_in_the_array
    stack = new_stack

    assert_equal({ "Fn::Select" => [ 2, [ { "Fn::If" => [ "xyz", "yep", { "Ref" => "AWS::NoValue" } ] }, "you", "dude" ] ] },
      stack.resolve(Fn.select(2, [ Fn.if("xyz", "yep", Fn::NO_VALUE), "you", "dude" ])))
  end

  # test('Fn.split')
  def test_fn_split
    assert_equal [ "hello", "world", "yeah" ], Fn.split(":", "hello:world:yeah")
  end

  # describe('FnJoin')

  # test('rejects empty list of arguments to join')
  def test_rejects_empty_list_of_arguments_to_join
    assert_raises(RubyCdk::Error) { Fn.join(".", []) }
  end

  # test('collapse nested FnJoins even if they contain tokens')
  def test_collapse_nested_fn_joins_even_if_they_contain_tokens
    stack = new_stack

    obj = Fn.join("", [ "a", Fn.join("", [ Fn.get_att("a", "bc"), "c" ]), "d" ])

    assert_equal({ "Fn::Join" => [ "", [ "a", { "Fn::GetAtt" => [ "a", "bc" ] }, "cd" ] ] }, stack.resolve(obj))
  end

  # test('resolves to the value if only one value is joined')
  def test_resolves_to_the_value_if_only_one_value_is_joined
    stack = new_stack

    values = [
      "x", "hello world", "ünïcödé", "with \"quotes\"", "with\\backslash", "${Braces}", "a" * 16,
      { "abc" => "def" }, { "Fn::GetAtt" => [ "a", "bc" ] }
    ]
    delimiters = [ "", "-", " ", "::", "ünï", ".", ", " ]

    delimiters.product(values).each do |delimiter, value|
      assert_equal value, stack.resolve(Fn.join(delimiter, [ value ])), "one value #{value.inspect} with the delimiter #{delimiter.inspect}"
    end
  end

  # test('pre-concatenates string literals')
  def test_pre_concatenates_string_literals
    stack = new_stack

    cases = [
      [ "", [ "a" ] ], [ "", %w[ a b c ] ], [ "-", %w[ a b c ] ], [ "::", %w[ arn aws s3 ] ],
      [ ", ", %w[ x y ] ], [ "ünï", %w[ a b ] ], [ "long delimiter", %w[ one two three ] ]
    ]

    cases.each do |delimiter, values|
      assert_equal values.join(delimiter), stack.resolve(Fn.join(delimiter, values)), "with the delimiter #{delimiter.inspect}"
    end
  end

  # test('pre-concatenates around tokens')
  def test_pre_concatenates_around_tokens
    stack = new_stack

    objects = [ { "Fn::GetAtt" => [ "a", "bc" ] }, { "Fn::ImportValue" => "Shared" }, { "abc" => "def" } ]
    layouts = [ [ "-", %w[ x ], %w[ y ] ], [ "", %w[ a b c ], %w[ d e f ] ], [ " and ", %w[ one two ], %w[ three ] ] ]

    layouts.each do |delimiter, prefix, suffix|
      objects.each do |obj|
        expected = { "Fn::Join" => [ delimiter, [ prefix.join(delimiter), obj, suffix.join(delimiter) ] ] }

        assert_equal expected, stack.resolve(Fn.join(delimiter, [ *prefix, obj, *suffix ])),
          "#{prefix.inspect} then #{obj.inspect} then #{suffix.inspect}, with the delimiter #{delimiter.inspect}"
      end
    end
  end

  # test('flattens joins nested under joins with same delimiter')
  def test_flattens_joins_nested_under_joins_with_same_delimiter
    stack = new_stack

    object = { "abc" => "def" }
    intrinsic = { "Fn::GetAtt" => [ "a", "bc" ] }
    delimiters = [ "", "-", "." ]
    prefixes = [ [], [ "a" ], [ object ], %w[ a b ], [ "a", object, "b" ] ]
    nested = [ [ "m" ], [ object ], [ intrinsic ], %w[ m n o ], [ "m", "", "n" ], [ "m", object, "n" ] ]
    suffixes = [ [], [ "z" ], [ intrinsic ], %w[ y z ], [ object, "" ] ]

    delimiters.product(prefixes, nested, suffixes).each do |delimiter, prefix, inner, suffix|
      flattened = stack.resolve(Fn.join(delimiter, [ *prefix, Fn.join(delimiter, inner), *suffix ]))
      written_out = stack.resolve(Fn.join(delimiter, [ *prefix, *inner, *suffix ]))

      assert_equal written_out, flattened,
        "prefix #{prefix.inspect}, nested #{inner.inspect}, suffix #{suffix.inspect}, with the delimiter #{delimiter.inspect}"
    end
  end

  # test('does not flatten joins nested under joins with different delimiter')
  def test_does_not_flatten_joins_nested_under_joins_with_different_delimiter
    stack = new_stack

    [ [ ".", "," ], [ "", "-" ], [ "-", "." ] ].each do |delimiter1, delimiter2|
      join = Fn.join(delimiter1, [ "a", "b", Fn.join(delimiter2, [ { "Fn::ImportValue" => "One" }, { "Fn::ImportValue" => "Two" } ]), "c", "d", "e" ])
      resolved = stack.resolve(join)
      kept = resolved["Fn::Join"][1].find { |element| element.is_a?(Hash) && element.key?("Fn::Join") && element["Fn::Join"][0] == delimiter2 }

      refute_nil kept, "the join with the delimiter #{delimiter2.inspect} inside the join with #{delimiter1.inspect}"
    end
  end

  # describe('Ref')

  # test('returns a reference given a logical name')
  def test_returns_a_reference_given_a_logical_name
    stack = new_stack

    assert_equal({ "Ref" => "hello" }, stack.resolve(Fn.ref("hello")))
  end

  # test('Fn.split with an unknown length resolves to simple {Fn::Split}')
  def test_fn_split_with_an_unknown_length_resolves_to_simple_fn_split
    stack = new_stack

    splittable = { "ThisIsASplittable" => "list" }
    split = Fn.split(",", splittable)

    assert_equal({ "Fn::Split" => [ ",", { "ThisIsASplittable" => "list" } ] }, stack.resolve(split))
  end

  # test('Fn.split with an assumed length resolves to a list of {Fn::Select}s')
  def test_fn_split_with_an_assumed_length_resolves_to_a_list_of_fn_selects
    stack = new_stack

    splittable = { "ThisIsASplittable" => "list" }
    split = Fn.split(",", splittable, 3)

    split_value = { "Fn::Split" => [ ",", { "ThisIsASplittable" => "list" } ] }
    assert_equal [ { "Fn::Select" => [ 0, split_value ] }, { "Fn::Select" => [ 1, split_value ] }, { "Fn::Select" => [ 2, split_value ] } ],
      stack.resolve(split)
  end

  # test('Fn.importListValue produces lists of known length')
  def test_fn_import_list_value_produces_lists_of_known_length
    stack = new_stack

    split = Fn.import_list_value("ExportName", 3)

    split_value = { "Fn::Split" => [ ",", { "Fn::ImportValue" => "ExportName" } ] }
    assert_equal [ { "Fn::Select" => [ 0, split_value ] }, { "Fn::Select" => [ 1, split_value ] }, { "Fn::Select" => [ 2, split_value ] } ],
      stack.resolve(split)
  end

  private

  # The origin's `new Stack()`: a stack with nothing in it, to resolve against.
  def new_stack
    RubyCdk::Stack.new(build_app, "Stack")
  end
end
