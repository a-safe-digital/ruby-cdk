# frozen_string_literal: true

require "test_helper"

# This tool's own tests of Fn. The CDK's own cases for it are in test/cdk/core/fn_test.rb.
class FnTest < Minitest::Test
  Target = Struct.new(:logical_id)
  NamedCondition = Struct.new(:name)

  def test_ref_takes_a_string_a_symbol_or_a_resource
    assert_equal({ "Ref" => "Table" }, RubyCdk::Fn.ref("Table"))
    assert_equal({ "Ref" => "Table" }, RubyCdk::Fn.ref(:Table))
    assert_equal({ "Ref" => "Table" }, RubyCdk::Fn.ref(Target.new("Table")))
  end

  def test_ref_and_get_att_take_nothing_else
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Fn.ref(Object.new) }

    assert_match(/\AFn\.ref takes a resource, a parameter or a logical ID, got #<Object:/, error.message)
    assert_raises(RubyCdk::UsageError) { RubyCdk::Fn.get_att(42, "Arn") }
  end

  def test_get_att
    assert_equal({ "Fn::GetAtt" => [ "FnRole", "Arn" ] }, RubyCdk::Fn.get_att(Target.new("FnRole"), "Arn"))
    assert_equal({ "Fn::GetAtt" => [ "FnRole", "Arn" ] }, RubyCdk::Fn.get_att("FnRole", :Arn))
  end

  def test_sub_with_and_without_variables
    assert_equal({ "Fn::Sub" => "${Table}" }, RubyCdk::Fn.sub("${Table}"))
    assert_equal({ "Fn::Sub" => [ "Hi ${Name}", { "Name" => "x" } ] }, RubyCdk::Fn.sub("Hi ${Name}", Name: "x"))
    assert_equal({ "Fn::Sub" => [ "Hi ${Name}", { "Name" => "x" } ] }, RubyCdk::Fn.sub("Hi ${Name}", "Name" => "x"))

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Fn.sub("Hi ${Name}", 1 => "x") }

    assert_equal "The keys of Fn.sub variables must be Strings or Symbols, got 1", error.message
  end

  def test_join_takes_the_list_as_one_array_or_as_several_arguments
    assert_equal({ "Fn::Join" => [ "", [ "a", "b" ] ] }, RubyCdk::Fn.join("", "a", "b"))
    assert_equal({ "Fn::Join" => [ "-", [ "a", "b" ] ] }, RubyCdk::Fn.join("-", [ "a", "b" ]))
    assert_equal({ "Fn::Join" => [ "-", [ "a", "b", "c" ] ] }, RubyCdk::Fn.join("-", [ "a" ], "b", "c"))
    assert_equal({ "Fn::Join" => [ ",", %w[ a b ] ] }, RubyCdk::Fn.join(",", RubyCdk::Fn.split(",", "a,b")))
  end

  def test_join_needs_at_least_one_value
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Fn.join(".", []) }

    assert_equal "Fn.join requires at least one value to be provided", error.message
    assert_raises(RubyCdk::UsageError) { RubyCdk::Fn.join(".") }
  end

  def test_select_answers_the_element_when_nothing_in_it_is_deferred_and_an_fn_select_otherwise
    assert_equal "a", RubyCdk::Fn.select(0, %w[ a b ])
    assert_equal({ "Plain" => 1 }, RubyCdk::Fn.select(0, [ { "Plain" => 1 }, "b" ]))
    assert_nil RubyCdk::Fn.select(5, %w[ a b ])

    assert_equal({ "Fn::Select" => [ 1, [ { "Ref" => "A" }, "b" ] ] }, RubyCdk::Fn.select(1, [ RubyCdk::Fn.ref("A"), "b" ]))
    assert_equal({ "Fn::Select" => [ 0, { "Fn::GetAZs" => "" } ] }, RubyCdk::Fn.select(0, RubyCdk::Fn.get_azs))
    assert_equal({ "Fn::Select" => [ "1", %w[ a b ] ] }, RubyCdk::Fn.select("1", %w[ a b ]))
    assert_equal({ "Fn::Select" => [ 1, [ [ RubyCdk::Fn.ref("A") ], "b" ] ] }, RubyCdk::Fn.select(1, [ [ RubyCdk::Fn.ref("A") ], "b" ]))
    deferred = RubyCdk::Fn.select(1, [ RubyCdk::Lazy.new { 0 }, "b" ])
    assert_equal 1, deferred["Fn::Select"][0]
    assert_kind_of RubyCdk::Lazy, deferred["Fn::Select"][1][0]

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Fn.select(0, "not a list") }

    assert_equal "Fn.select takes an Array or a function that returns a list, got \"not a list\"", error.message
  end

  def test_split_answers_the_list_when_the_string_is_known_and_an_fn_split_otherwise
    assert_equal %w[ hello world yeah ], RubyCdk::Fn.split(":", "hello:world:yeah")
    assert_equal [ "a", "", "b" ], RubyCdk::Fn.split(",", "a,,b")
    assert_equal [ "a", "" ], RubyCdk::Fn.split(",", "a,")
    assert_equal [ "" ], RubyCdk::Fn.split(",", "")
    assert_equal %w[ a b ], RubyCdk::Fn.split("", "ab")
    assert_equal [ "a", "", "", "b" ], RubyCdk::Fn.split(" ", "a   b")

    assert_equal({ "Fn::Split" => [ ",", RubyCdk::Fn.import_value("Shared") ] }, RubyCdk::Fn.split(",", RubyCdk::Fn.import_value("Shared")))
    later = RubyCdk::Lazy.new { "a,b" }
    assert_equal [ ",", later ], RubyCdk::Fn.split(",", later)["Fn::Split"]
    assert_equal %w[ a b ], RubyCdk::Fn.split(",", "a,b", 3)

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Fn.split(nil, "a,b") }

    assert_equal "Fn.split takes a String separator, got nil", error.message
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Fn.split(",", RubyCdk::Fn.import_value("X"), -1) }
    assert_equal "Fn.split: assumed_length must be an Integer of at least 0, got -1", error.message
  end

  def test_a_split_of_an_unknown_length_with_an_assumed_length_is_a_list_of_known_length
    split = RubyCdk::Fn.split(",", RubyCdk::Fn.import_value("X"))

    assert_equal [ { "Fn::Select" => [ 0, split ] }, { "Fn::Select" => [ 1, split ] } ], RubyCdk::Fn.split(",", RubyCdk::Fn.import_value("X"), 2)
    assert_equal [], RubyCdk::Fn.split(",", RubyCdk::Fn.import_value("X"), 0)
  end

  def test_import_list_value_is_a_split_on_commas_of_an_import
    split = { "Fn::Split" => [ ",", { "Fn::ImportValue" => "ExportName" } ] }

    assert_equal [ { "Fn::Select" => [ 0, split ] }, { "Fn::Select" => [ 1, split ] } ], RubyCdk::Fn.import_list_value("ExportName", 2)
    other = RubyCdk::Fn.import_list_value(:ExportName, 1, "|")
    assert_equal({ "Fn::Split" => [ "|", { "Fn::ImportValue" => "ExportName" } ] }, other.first["Fn::Select"][1])
  end

  def test_minimal_join_splices_a_join_with_the_same_delimiter_and_glues_neighbouring_literals
    assert_equal [ "a-b" ], RubyCdk::Fn.minimal_join("-", [ "a", "b" ])
    assert_equal [ { "Ref" => "A" }, "b-c" ], RubyCdk::Fn.minimal_join("-", [ { "Ref" => "A" }, "b", "c" ])
    assert_equal [ "a-b", { "Ref" => "A" }, "c-d" ], RubyCdk::Fn.minimal_join("-", [ "a", "b", { "Ref" => "A" }, "c", "d" ])
    assert_equal [ "abc" ], RubyCdk::Fn.minimal_join("", [ "a", "b", "c" ])
    assert_equal [ { "Plain" => 1 } ], RubyCdk::Fn.minimal_join("", [ { "Plain" => 1 } ])
    assert_equal [], RubyCdk::Fn.minimal_join("", [])

    same = { "Fn::Join" => [ "-", [ "b", { "Ref" => "A" }, "c" ] ] }
    other = { "Fn::Join" => [ ":", [ "x", "y" ] ] }
    assert_equal [ "a-b", { "Ref" => "A" }, "c-d" ], RubyCdk::Fn.minimal_join("-", [ "a", same, "d" ])
    assert_equal [ "a", other, "d" ], RubyCdk::Fn.minimal_join("-", [ "a", other, "d" ])
    assert_equal [ "a", { "Fn::Join" => [ "-", { "Ref" => "A" } ] }, "d" ], RubyCdk::Fn.minimal_join("-", [ "a", { "Fn::Join" => [ "-", { "Ref" => "A" } ] }, "d" ])

    values = [ "a", "b" ]
    RubyCdk::Fn.minimal_join("-", values)
    assert_equal [ "a", "b" ], values
  end

  def test_minimal_join_writes_a_number_the_way_javascript_does
    assert_equal [ "1-2" ], RubyCdk::Fn.minimal_join("-", [ 1, 2 ])
    assert_equal "3-4.5", RubyCdk::Fn.minimal_join("-", [ 3, 4.5 ]).first
    assert_equal "1-2.5", RubyCdk::Fn.minimal_join("-", [ 1.0, 2.5 ]).first
    assert_equal [ 1.0 ], RubyCdk::Fn.minimal_join("-", [ 1.0 ])
  end

  def test_base64_import_value_and_get_azs
    assert_equal({ "Fn::Base64" => "text" }, RubyCdk::Fn.base64("text"))
    assert_equal({ "Fn::ImportValue" => "Net-Bucket" }, RubyCdk::Fn.import_value("Net-Bucket"))
    assert_equal({ "Fn::ImportValue" => "Net" }, RubyCdk::Fn.import_value(:Net))

    assert_equal({ "Fn::GetAZs" => "" }, RubyCdk::Fn.get_azs)
    assert_equal({ "Fn::GetAZs" => "" }, RubyCdk::Fn.get_azs(nil))
    assert_equal({ "Fn::GetAZs" => "eu-west-1" }, RubyCdk::Fn.get_azs("eu-west-1"))
    assert_equal({ "Fn::GetAZs" => { "Ref" => "AWS::Region" } }, RubyCdk::Fn.get_azs(RubyCdk::Fn.ref("AWS::Region")))
  end

  def test_find_in_map
    assert_equal({ "Fn::FindInMap" => [ "Regions", "eu", "west" ] }, RubyCdk::Fn.find_in_map(:Regions, "eu", "west"))
    assert_equal({ "Fn::FindInMap" => [ "Regions", "eu", "west" ] }, RubyCdk::Fn.find_in_map("Regions", "eu", "west"))
  end

  def test_conditions
    condition = { "Fn::Equals" => [ "a", "a" ] }
    assert_equal({ "Fn::If" => [ "IsA", "yes", "no" ] }, RubyCdk::Fn.if("IsA", "yes", "no"))
    assert_equal({ "Fn::If" => [ "IsA", "yes", "no" ] }, RubyCdk::Fn.if(NamedCondition.new("IsA"), "yes", "no"))
    assert_equal condition, RubyCdk::Fn.equals("a", "a")
    assert_equal({ "Fn::And" => [ condition ] }, RubyCdk::Fn.and_(condition))
    assert_equal({ "Fn::Or" => [ condition ] }, RubyCdk::Fn.or_(condition))
    assert_equal({ "Fn::Not" => [ condition ] }, RubyCdk::Fn.not_(condition))

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Fn.if(Object.new, "yes", "no") }

    assert_match(/\AFn\.if takes a condition the stack declared, or its name, got /, error.message)
  end

  def test_no_value_is_frozen
    assert_predicate RubyCdk::Fn::NO_VALUE, :frozen?
  end
end
