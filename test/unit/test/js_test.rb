# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/test"

# This tool's own tests of the JavaScript that the matcher engine's messages are
# written in, reproduced in Ruby by RubyCdk::Test::Private::Js. The CDK has no
# such file: each case states what V8 does, by its specification.
class TestKitJsTest < Minitest::Test
  # The module's private helper, by a short name. Not part of the public API.
  Js = RubyCdk::Test::Private::Js
  UNDEFINED = RubyCdk::Test::UNDEFINED

  def test_typeof_as_javascript_has_it_null_included
    types = {
      UNDEFINED => "undefined", nil => "object", true => "boolean", false => "boolean",
      1 => "number", 1.5 => "number", "s" => "string", :sym => "symbol",
      [] => "object", {} => "object", Object.new => "object"
    }

    types.each { |value, expected| assert_equal expected, Js.typeof(value), "typeof #{value.inspect}" }
  end

  def test_object_is_true_of_neither_null_nor_undefined_nor_a_primitive
    assert Js.object?({})
    assert Js.object?([])
    refute Js.object?(nil)
    refute Js.object?(UNDEFINED)
    refute Js.object?("s")
    refute Js.object?(1)
  end

  def test_string_as_javascript_prints_it
    strings = {
      UNDEFINED => "undefined", nil => "null", true => "true", false => "false",
      1 => "1", "s" => "s", [ 1, "a" ] => "1,a", [ 1, nil, UNDEFINED ] => "1,,", {} => "[object Object]"
    }

    strings.each { |value, expected| assert_equal expected, Js.string(value), "String(#{value.inspect})" }
  end

  def test_a_number_is_printed_as_javascript_prints_it
    numbers = {
      2.0 => "2", -2.0 => "-2", 2.5 => "2.5", 0.1 => "0.1", 1e20 => "100000000000000000000",
      1e21 => "1e+21", 1.5e21 => "1.5e+21", 0.00001 => "0.00001", 0.000001 => "0.000001",
      1e-7 => "1e-7", 1.5e-7 => "1.5e-7", Float::NAN => "NaN", Float::INFINITY => "Infinity"
    }

    numbers.each { |value, expected| assert_equal expected, Js.number_string(value), "String(#{value})" }
    assert_equal "2", Js.string(2.0)
  end

  def test_json_is_json_stringify_compact_or_indented
    value = { "a" => [ 1, 2 ], "b" => { "c" => nil }, "d" => 2.0 }

    assert_equal '{"a":[1,2],"b":{"c":null},"d":2}', Js.json(value)
    assert_equal "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {\n    \"c\": null\n  },\n  \"d\": 2\n}", Js.json(value, 2)
    assert_equal "[\n 1,\n 2\n]", Js.json([ 1, 2 ], 1)
  end

  def test_json_prints_nothing_where_javascript_prints_nothing
    [ UNDEFINED, :sym, -> { } ].each do |value|
      assert_nil Js.json(value), "JSON.stringify(#{value.inspect})"
      assert_equal "undefined", Js.jsonify(value)
    end
    assert_equal "null", Js.json(Float::NAN)
    assert_equal "null", Js.jsonify(Float::INFINITY)
  end

  def test_json_leaves_out_what_javascript_leaves_out_and_nulls_it_in_an_array
    assert_equal "{}", Js.json({ "a" => UNDEFINED })
    assert_equal '{"b":null}', Js.json({ "a" => UNDEFINED, "b" => nil })
    assert_equal "[null,1]", Js.json([ UNDEFINED, 1 ])
    assert_equal "{}", Js.json(Object.new)
    assert_equal "{\"a\":1}", Js.json(Struct.new(:a).new(1))
  end

  def test_json_escapes_only_what_json_requires
    text = "\"\\\e\b\f\n\r\t\u007f\u2028é"

    assert_equal JSON.generate(text), Js.json(text)
    assert_equal "\"\\\"\\\\\\u001b\\b\\f\\n\\r\\t\u007f\u2028é\"", Js.json(text)
  end

  def test_object_keys_lists_the_array_indexes_first_by_number_then_the_rest_in_order
    keys = Js.object_keys({ "b" => 1, "10" => 1, "1" => 1, "0" => 1, "a" => 1, "01" => 1 })

    assert_equal [ "0", "1", "10", "b", "a", "01" ], keys
    assert_equal [ "0", "1" ], Js.object_keys([ "x", "y" ])
    assert_equal [ "b" ], Js.json({ "b" => 1, "a" => UNDEFINED }).then { |json| JSON.parse(json).keys }
  end

  def test_object_keys_of_null_is_a_type_error_as_it_is_there
    error = assert_raises(TypeError) { Js.object_keys(nil) }

    assert_equal "Cannot convert undefined or null to object", error.message
    assert_raises(TypeError) { Js.object_keys(UNDEFINED) }
    assert_equal [], Js.object_keys("abc")
  end

  def test_entries_walks_an_array_by_index_as_javascript_does
    assert_equal [ [ "0", "x" ], [ "1", "y" ] ], Js.entries([ "x", "y" ])
    assert_equal [ [ "a", 1 ] ], Js.entries({ "a" => 1 })
  end

  def test_get_is_undefined_where_there_is_nothing
    value = { "a" => nil }

    assert_nil Js.get(value, "a")
    assert_same UNDEFINED, Js.get(value, "b")
    assert_same UNDEFINED, Js.get(value, :a)
    assert_equal "x", Js.get([ "x" ], "0")
    assert_same UNDEFINED, Js.get([ "x" ], "1")
    assert_same UNDEFINED, Js.get(5, "a")
  end

  def test_in_is_a_type_error_on_a_null_or_a_primitive
    assert Js.in?("a", { "a" => 1 })
    refute Js.in?("b", { "a" => 1 })
    assert Js.in?("1", [ "x", "y" ])
    refute Js.in?("2", [ "x", "y" ])

    error = assert_raises(TypeError) { Js.in?("a", nil) }
    assert_equal "Cannot use 'in' operator to search for 'a' in null", error.message
    assert_raises(TypeError) { Js.in?("a", 5) }
    assert_raises(TypeError) { Js.in?("a", UNDEFINED) }
  end

  def test_strict_equal_compares_primitives_by_value_and_the_rest_by_identity
    hash = {}

    assert Js.strict_equal?(1, 1.0)
    assert Js.strict_equal?("a", "a")
    assert Js.strict_equal?(nil, nil)
    assert Js.strict_equal?(UNDEFINED, UNDEFINED)
    refute Js.strict_equal?(1, "1")
    refute Js.strict_equal?(nil, UNDEFINED)
    refute Js.strict_equal?(nil, false)
    refute Js.strict_equal?({}, {})
    assert Js.strict_equal?(hash, hash)
  end

  def test_normalize_turns_symbols_into_strings_and_leaves_matchers_alone
    any = RubyCdk::Test.any_value
    pattern = { a: [ :sym, { b: any } ], "kept" => :v }

    normalized = Js.normalize(pattern)

    assert_equal({ "a" => [ "sym", { "b" => any } ], "kept" => "v" }, normalized)
    assert_same any, normalized["a"][1]["b"]
    assert_equal [ :a, "kept" ], pattern.keys
    assert_equal :sym, pattern[:a][0]
  end

  def test_deep_copy_copies_the_containers_and_shares_the_rest
    inner = { "a" => [ 1 ] }
    original = { "x" => inner, "n" => 1 }
    copy = Js.deep_copy(original)

    assert_equal original, copy
    refute_same original, copy
    refute_same inner, copy["x"]
    assert_same 1, copy["n"]
    copy["x"]["a"] << 2
    assert_equal [ 1 ], inner["a"]
    assert_equal "s", Js.deep_copy("s")
  end

  def test_trim_end_removes_the_trailing_whitespace_only
    assert_equal "a\n  b", Js.trim_end("a\n  b \n\t\n")
    assert_equal "  a", Js.trim_end("  a")
    assert_equal "", Js.trim_end(" \n ")
  end

  def test_move_markers_to_front_keeps_all_but_two_of_the_spaces_after_the_marker
    assert_equal "!! msg\n  x\n!!    msg", Js.move_markers_to_front("!! msg\n  x\n    !!  msg")
    assert_equal "!!x", Js.move_markers_to_front("  !!x")
    assert_equal "unchanged", Js.move_markers_to_front("unchanged")
  end

  def test_an_abridged_value
    abridged = Js.method(:render_abridged)

    assert_equal "[]", abridged.call([])
    assert_equal "[ 1 ]", abridged.call([ 1 ])
    assert_equal "[ \"a\" ]", abridged.call([ "a" ])
    assert_equal "[ 1, \"a\" ]", abridged.call([ 1, "a" ])
    assert_equal "[ ... ]", abridged.call([ [ 1 ], {} ])
    assert_equal "[ ... ]", abridged.call([ 1, {} ])
    assert_equal "[ ... ]", abridged.call([ 1, 2, 3 ])
    assert_equal "{}", abridged.call({})
    assert_equal "{ \"a\": [ 1, 2 ] }", abridged.call({ "a" => [ 1, 2 ] })
    assert_equal "{ ... }", abridged.call({ "a" => 1, "b" => 2 })
    assert_equal "null", abridged.call(nil)
    assert_equal "undefined", abridged.call(UNDEFINED)
    assert_equal "\"s\"", abridged.call("s")
  end

  def test_locale_compare_ignores_case_first_and_puts_lower_case_before_upper_case
    assert_operator Js.locale_compare("a", "b"), :<, 0
    assert_operator Js.locale_compare("a", "B"), :<, 0
    assert_operator Js.locale_compare("Zeta", "alpha"), :>, 0
    assert_operator Js.locale_compare("foo", "Foo"), :<, 0
    assert_operator Js.locale_compare("Bar", "foo"), :<, 0
    assert_equal 0, Js.locale_compare("a", "a")
    assert_operator Js.locale_compare("1", "a"), :<, 0
  end

  def test_the_comparator_sorts_by_key_and_puts_the_longer_key_first
    comparator = RubyCdk::Test::Private.sort_key_comparator { |entry| entry }

    assert_equal [ [ 1, "b" ], [ 2, "a" ], [ 2, "b", 1 ], [ 2, "b" ] ],
      [ [ 2, "b", 1 ], [ 2, "b" ], [ 2, "a" ], [ 1, "b" ] ].sort(&comparator)
    assert_equal [ "a", "B" ], [ "B", "a" ].sort { |left, right| comparator.call([ left ], [ right ]) }
  end

  def test_the_sparse_matrix_remembers_what_was_set_where_and_in_which_order
    matrix = RubyCdk::Test::Private::SparseMatrix.new
    matrix.set(0, 2, "c")
    matrix.set(0, 1, "b")
    matrix.set(1, 0, "d")

    assert_equal "b", matrix.get(0, 1)
    assert_nil matrix.get(0, 0)
    assert_nil matrix.get(5, 0)
    assert_equal [ [ 2, "c" ], [ 1, "b" ] ], matrix.row(0)
    assert_equal [ [ 0, "d" ] ], matrix.row(1)
    assert_equal [], matrix.row(2)
  end

  def test_get_type_names_an_array_apart
    get_type = RubyCdk::Test::Private.method(:get_type)

    assert_equal "array", get_type.call([])
    assert_equal "object", get_type.call({})
    assert_equal "object", get_type.call(nil)
    assert_equal "undefined", get_type.call(UNDEFINED)
    assert_equal "string", get_type.call("s")
  end
end
