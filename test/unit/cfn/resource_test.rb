# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# L1: Construct#resource and Cfn::Resource.
class CfnResourceTest < CoreHelpers::TestCase
  def test_resource_creates_the_l1_resource_and_returns_it
    stack = build_stack do
      @table = resource("Table", "AWS::DynamoDB::Table", "KeySchema" => [], TableName: "data", Timeout: 10)
    end
    table = stack.instance_variable_get(:@table)

    assert_kind_of RubyCdk::Cfn::Resource, table
    assert_kind_of RubyCdk::Construct, table
    assert_equal "AWS::DynamoDB::Table", table.type
    assert_equal "Table", table.logical_id
    assert_equal "Table", table.id
    assert_equal "App/blog/Table", table.path
    assert_equal [ table ], stack.resources
    assert_equal [ table ], stack.children
    assert_equal({ "KeySchema" => [], TableName: "data", Timeout: 10 }, table.properties)
    assert_equal [], table.depends_on
    assert_nil table.condition
    assert_nil table.deletion_policy
    assert_nil table.update_replace_policy
    assert_equal({}, table.metadata)
  end

  def test_the_properties_are_keywords_or_one_explicit_hash
    stack = build_stack do
      @keywords = resource("A", "AWS::SQS::Queue", VisibilityTimeout: 30)
      @hash = resource("B", "AWS::SQS::Queue", properties: { "VisibilityTimeout" => 30, "Condition" => "IsProd", "Metadata" => { "a" => 1 } })
    end

    # The keys are kept as the user wrote them until the template is resolved.
    assert_equal({ VisibilityTimeout: 30 }, stack.instance_variable_get(:@keywords).properties)
    assert_equal({ "VisibilityTimeout" => 30, "Condition" => "IsProd", "Metadata" => { "a" => 1 } }, stack.instance_variable_get(:@hash).properties)
    assert_equal({}, build_stack { resource("C", "AWS::SQS::Queue") }.resources.first.properties)
  end

  def test_properties_cannot_be_combined_with_other_keywords
    stack = build_stack

    error = assert_raises(RubyCdk::UsageError) do
      stack.resource("A", "AWS::SQS::Queue", properties: { "DelaySeconds" => 1 }, VisibilityTimeout: 30)
    end

    assert_match(/resource "A" in App\/blog: properties: cannot be combined with other keywords/, error.message)
    assert_raises(RubyCdk::UsageError) { stack.resource("B", "AWS::SQS::Queue", properties: "not a hash") }
    assert_empty stack.resources
    assert_empty stack.children
  end

  def test_the_keys_are_kept_exactly_as_written_symbols_and_all
    stack = build_stack do
      @resource = resource("A", "AWS::DynamoDB::Table", key_schema: [ { attribute_name: "pk", key_type: "HASH" } ],
        attribute_definitions: [ { attribute_name: "pk", attribute_type: "S" } ], BillingMode: :PAY_PER_REQUEST)
    end

    assert_equal({
      key_schema: [ { attribute_name: "pk", key_type: "HASH" } ],
      attribute_definitions: [ { attribute_name: "pk", attribute_type: "S" } ],
      BillingMode: :PAY_PER_REQUEST
    }, stack.instance_variable_get(:@resource).properties)
    assert_equal({
      "KeySchema" => [ { "AttributeName" => "pk", "KeyType" => "HASH" } ],
      "AttributeDefinitions" => [ { "AttributeName" => "pk", "AttributeType" => "S" } ],
      "BillingMode" => "PAY_PER_REQUEST"
    }, stack.to_template["Resources"]["A"]["Properties"])
  end

  def test_the_type_must_be_a_name
    stack = build_stack

    assert_equal "AWS::SNS::Topic", stack.resource("A", "AWS::SNS::Topic").type
    assert_raises(RubyCdk::UsageError) { stack.resource("B", "") }
    assert_raises(RubyCdk::UsageError) { stack.resource("C", nil) }
    assert_raises(RubyCdk::UsageError) { stack.resource("D", :"") }
    assert_equal %w[ A ], stack.resources.map(&:logical_id)
  end

  def test_depends_on_takes_resources_parameters_or_names
    stack = build_stack do
      parameter("Stage", type: "String")
      @first = resource("First", "AWS::SNS::Topic")
      @second = resource("Second", "AWS::SQS::Queue", depends_on: [ @first, "Stage", :Other ])
      @single = resource("Third", "AWS::SQS::Queue", depends_on: @first)
      @named = resource("Fourth", "AWS::SQS::Queue", depends_on: "Other")
      @none = resource("Fifth", "AWS::SQS::Queue", depends_on: nil)
    end

    assert_equal %w[ First Stage Other ], stack.instance_variable_get(:@second).depends_on
    assert_equal %w[ First ], stack.instance_variable_get(:@single).depends_on
    assert_equal %w[ Other ], stack.instance_variable_get(:@named).depends_on
    assert_equal [], stack.instance_variable_get(:@none).depends_on
  end

  def test_depends_on_takes_nothing_else
    stack = build_stack

    error = assert_raises(RubyCdk::UsageError) { stack.resource("A", "AWS::SQS::Queue", depends_on: stack) }

    assert_match(/resource "A" in App\/blog: depends_on takes a resource, a parameter or a logical ID/, error.message)
    assert_raises(RubyCdk::UsageError) { stack.resource("B", "AWS::SQS::Queue", depends_on: Object.new) }
    assert_empty stack.resources
  end

  def test_condition_takes_a_condition_of_the_stack_or_its_name
    stack = build_stack do
      @declared = condition("IsProd", Fn.equals("a", "a"))
      @from_handle = resource("A", "AWS::SNS::Topic", condition: @declared)
      @from_string = resource("B", "AWS::SNS::Topic", condition: "IsProd")
      @from_symbol = resource("C", "AWS::SNS::Topic", condition: :IsProd)
    end

    assert_equal "IsProd", stack.instance_variable_get(:@from_handle).condition
    assert_equal "IsProd", stack.instance_variable_get(:@from_string).condition
    assert_equal "IsProd", stack.instance_variable_get(:@from_symbol).condition
    assert_equal "IsProd", stack.to_template["Resources"]["A"]["Condition"]

    error = assert_raises(RubyCdk::UsageError) { stack.resource("D", "AWS::SNS::Topic", condition: Fn.equals("a", "a")) }

    assert_match(/resource "D" in App\/blog: condition takes a condition the stack declared, or its name/, error.message)
  end

  def test_the_policies_are_kept_as_cloudformation_names
    stack = build_stack do
      @kept = resource("Bucket", "AWS::S3::Bucket", deletion_policy: :retain, update_replace_policy: "Delete")
      @deleted = resource("Table", "AWS::DynamoDB::Table", deletion_policy: :delete)
    end

    assert_equal "Retain", stack.instance_variable_get(:@kept).deletion_policy
    assert_equal "Delete", stack.instance_variable_get(:@kept).update_replace_policy
    assert_equal "Delete", stack.instance_variable_get(:@deleted).deletion_policy
    assert_nil stack.instance_variable_get(:@deleted).update_replace_policy

    error = assert_raises(RubyCdk::UsageError) { stack.resource("A", "AWS::SQS::Queue", update_replace_policy: :retain_except_on_create) }

    assert_match(/resource "A" in App\/blog: update_replace_policy: :retain_except_on_create is not one of/, error.message)
  end

  def test_metadata_is_a_hash_of_its_own
    stack = build_stack { @resource = resource("A", "AWS::SQS::Queue", metadata: { "Team" => "Platform" }) }
    source = { "Team" => "Platform" }

    stack.resource("B", "AWS::SQS::Queue", metadata: source)
    source["Changed"] = true

    assert_equal({ "Team" => "Platform" }, stack.resources.last.metadata)
    assert_raises(RubyCdk::UsageError) { stack.resource("C", "AWS::SQS::Queue", metadata: "Team") }
  end

  def test_the_resource_is_added_to_the_tree_under_the_construct_that_made_it
    stack = build_stack do
      api = RubyCdk::Construct.new(self, "Api")
      @role = api.resource("Role", "AWS::IAM::Role")
    end

    assert_equal "App/blog/Api/Role", stack.instance_variable_get(:@role).path
    assert_equal [ "Role" ], stack.children.last.children.map(&:id)
  end
end
