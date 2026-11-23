# frozen_string_literal: true

require "test_helper"

class FnTest < Minitest::Test
  Target = Struct.new(:logical_id)
  NamedCondition = Struct.new(:name)

  def test_ref_takes_a_string_a_symbol_or_a_resource
    assert_equal({ "Ref" => "Table" }, RubyCdk::Fn.ref("Table"))
    assert_equal({ "Ref" => "Table" }, RubyCdk::Fn.ref(:Table))
    assert_equal({ "Ref" => "Table" }, RubyCdk::Fn.ref(Target.new("Table")))
  end

  def test_get_att
    assert_equal({ "Fn::GetAtt" => [ "FnRole", "Arn" ] }, RubyCdk::Fn.get_att(Target.new("FnRole"), "Arn"))
    assert_equal({ "Fn::GetAtt" => [ "FnRole", "Arn" ] }, RubyCdk::Fn.get_att("FnRole", :Arn))
  end

  def test_sub_with_and_without_variables
    assert_equal({ "Fn::Sub" => "${Table}" }, RubyCdk::Fn.sub("${Table}"))
    assert_equal({ "Fn::Sub" => [ "Hi ${Name}", { "Name" => "x" } ] }, RubyCdk::Fn.sub("Hi ${Name}", Name: "x"))
  end

  def test_join_flattens_its_arguments
    assert_equal({ "Fn::Join" => [ "", [ "a", "b" ] ] }, RubyCdk::Fn.join("", "a", "b"))
    assert_equal({ "Fn::Join" => [ "-", [ "a", "b" ] ] }, RubyCdk::Fn.join("-", [ "a", "b" ]))
  end

  def test_select_writes_the_index_as_a_string
    assert_equal({ "Fn::Select" => [ "0", [ "a", "b" ] ] }, RubyCdk::Fn.select(0, %w[a b]))
  end

  def test_split_base64_import_value_and_get_azs
    assert_equal({ "Fn::Split" => [ ",", "a,b" ] }, RubyCdk::Fn.split(",", "a,b"))
    assert_equal({ "Fn::Base64" => "text" }, RubyCdk::Fn.base64("text"))
    assert_equal({ "Fn::ImportValue" => "Net-Bucket" }, RubyCdk::Fn.import_value("Net-Bucket"))
    assert_equal({ "Fn::GetAZs" => "AWS::Region" }, RubyCdk::Fn.get_azs)
    assert_equal({ "Fn::GetAZs" => "eu-west-1" }, RubyCdk::Fn.get_azs("eu-west-1"))
  end

  def test_find_in_map
    assert_equal({ "Fn::FindInMap" => [ "Regions", "eu", "west" ] }, RubyCdk::Fn.find_in_map(:Regions, "eu", "west"))
  end

  def test_conditions
    condition = { "Fn::Equals" => [ "a", "a" ] }
    assert_equal({ "Fn::If" => [ "IsA", "yes", "no" ] }, RubyCdk::Fn.if("IsA", "yes", "no"))
    assert_equal({ "Fn::If" => [ "IsA", "yes", "no" ] }, RubyCdk::Fn.if(NamedCondition.new("IsA"), "yes", "no"))
    assert_equal(condition, RubyCdk::Fn.equals("a", "a"))
    assert_equal({ "Fn::And" => [ condition ] }, RubyCdk::Fn.and_(condition))
    assert_equal({ "Fn::Or" => [ condition ] }, RubyCdk::Fn.or_(condition))
    assert_equal({ "Fn::Not" => [ condition ] }, RubyCdk::Fn.not_(condition))
  end

  def test_no_value_is_frozen
    assert_predicate RubyCdk::Fn::NO_VALUE, :frozen?
  end
end
