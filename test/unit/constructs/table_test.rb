# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/constructs"
require "ruby_cdk/test"
require "support/core_helpers"

# This tool's own tests of the DynamoDB table, what no CDK case reaches here
# (docs/07-testing.md section 10): the provisioned billing shape, the PITR
# override, twice in one stack, and the refusals.
class ConstructsTableTest < CoreHelpers::TestCase
  def test_a_table_used_twice_carries_two_distinct_resources
    app = build_app(env: TEST_ENV)
    stack = RubyCdk::Stack.new(app, "stack") do
      RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "id", type: :string }, table_name: "one")
      RubyCdk::DynamoDB::Table.new(self, "Table2", partition_key: { name: "id", type: :string }, table_name: "two")
    end
    template = RubyCdk::Test.template(stack)

    template.resource_count_is("AWS::DynamoDB::Table", 2)
    template.has_resource_properties("AWS::DynamoDB::Table", { "TableName" => "one" })
    template.has_resource_properties("AWS::DynamoDB::Table", { "TableName" => "two" })
  end

  def test_provisioned_billing_writes_the_throughput
    built, = build_stack do
      RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "id", type: :string },
        billing: :provisioned, read_capacity: 3, write_capacity: 7)
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", {
      "BillingMode" => RubyCdk::Test.absent(),
      "ProvisionedThroughput" => RubyCdk::Test.object_equals(
        "ReadCapacityUnits" => 3, "WriteCapacityUnits" => 7
      )
    })
  end

  def test_provisioned_billing_defaults_to_the_cdk_s_capacities
    built, = build_stack do
      RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "id", type: :string }, billing: :provisioned)
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", {
      "ProvisionedThroughput" => RubyCdk::Test.object_equals(
        "ReadCapacityUnits" => 5, "WriteCapacityUnits" => 5
      )
    })
  end

  def test_point_in_time_recovery_can_be_turned_off
    built, = build_stack do
      RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "id", type: :string },
        point_in_time_recovery: false)
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", {
      "PointInTimeRecoverySpecification" => RubyCdk::Test.object_equals("PointInTimeRecoveryEnabled" => false)
    })
  end

  def test_key_types_take_symbols_or_the_cdk_s_letters
    built, = build_stack do
      RubyCdk::DynamoDB::Table.new(self, "Table",
        partition_key: { name: "pk", type: :binary },
        sort_key: { name: "sk", type: :number })
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", {
      "AttributeDefinitions" => [
        { "AttributeName" => "pk", "AttributeType" => "B" },
        { "AttributeName" => "sk", "AttributeType" => "N" }
      ]
    })
  end

  def test_a_table_without_a_name_refers_to_its_resource
    _, table = build_stack do
      RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "id", type: :string })
    end

    assert_equal({ "Ref" => "TableResource" }, table.table_name)
  end

  def test_a_bad_key_or_billing_is_refused
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "id", type: :list }) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { type: :string }) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "id", type: :string }, billing: :fixed) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "id", type: :string }, point_in_time_recovery: nil) }
    end
  end

  def test_a_grant_to_an_arn_principal_is_returned_unapplied
    stack, table = build_stack do
      RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "id", type: :string })
    end

    grant = table.grant_read_data("arn:aws:iam::111122223333:user/alice")

    refute grant.applied?
    RubyCdk::Test.template(stack).resource_count_is("AWS::IAM::Policy", 0)
  end

  private

  # One stack in an App with the test env, whose build is the block. Answers
  # [stack, the block's value].
  def build_stack(&body)
    app = build_app(env: TEST_ENV)
    value = nil
    built = RubyCdk::Stack.new(app, "Stack") do
      value = instance_eval(&body)
    end
    [ built, value ]
  end

  def template(stack)
    RubyCdk::Test.template(stack)
  end
end
