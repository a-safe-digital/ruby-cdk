# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/aws-dynamodb/test/dynamodb.test.ts, in aws/aws-cdk
#   Commit:  c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-25)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 166 cases. Each ported one keeps its name, as a comment above
# the test, and what it expects. What changed to get there:
#
#   - The origin's `new Stack()` is `stack` here, `Template.fromStack` is
#     `template`. The partition key of the origin's shared cases is
#     { name: "hashKey", type: "S" } and its sort key { name: "sortKey",
#     type: "N" }, written the same way here.
#   - The logical ID is the ids above the resource joined, never hashed
#     (D-004, D-029): mytable0324D45C is TableResource here.
#
# Changed expectations, stated next to the test:
#
#   - Billing: this tool's default is on demand - BillingMode PAY_PER_REQUEST,
#     no ProvisionedThroughput - where the CDK's default is provisioned with 5
#     and 5 (table.ts:1347). The plan fixes on-demand as the default here, the
#     nag rule prices a table without point-in-time recovery, and section 7
#     wins where the CDK differs; the row is in section 21. The cases that
#     carry the origin's ProvisionedThroughput expectation instead carry this
#     tool's BillingMode.
#   - Point-in-time recovery is on by default, where the CDK writes no
#     specification (which leaves it off): every default-table expectation here
#     carries PointInTimeRecoverySpecification with PointInTimeRecoveryEnabled
#     true. The row is in section 21.
#   - Retention: the table is a retained type here, DeletionPolicy
#     RetainExceptOnCreate and UpdateReplacePolicy Retain, where the origin's
#     carries Retain on both (section 7 wins; the row is in section 21).
#
# Not ported, with the reason:
#
#   Not ported because this tool does not have the feature:
#   - removalPolicy is DESTROY. No removalPolicy prop on this construct; the
#     L1 resource's deletion_policy: is the way to write one, and section 7
#     keeps the table retained.
#   - "grantWriteData" allows the principal to write data to the table. There
#     is no write-only grant in this wave; grant_read_write_data is the write
#     grant, ported under its own case.
#   - point-in-time-recovery-specification enabled (with recoveryPeriodInDays),
#     both point-in-time-recovery-specification and point-in-time-recovery set,
#     recoveryPeriodInDays out of bounds, recoveryPeriodInDays with pitr
#     disabled. The recovery period is not a prop of this wave; the
#     specification is written with PointInTimeRecoveryEnabled alone.
#   - server-side encryption cases (customer managed CMK, encryptionKey only,
#     the three refusals, and the key grants). There is no KMS Key construct in
#     this wave.
#   - the stream cases beyond "not enabled" (new and old images, new images
#     only, old images only, the global-table replication cases). No stream or
#     replication props in this wave.
#   - ttl enabled, contributor insights, kinesis stream, table class, deletion
#     protection, warm throughput, import source, autoscaling, time to live.
#     Each is a prop this wave does not carry; the L1 resource: remains the way
#     to write one.
#   - fromTableArn / fromTableName / arnForTable of an imported table. Lookups
#     of existing resources are not in 0.1.0 (D-022).
#   - the replica removal-policy cases (global tables). No replicas here.
#   - the grants with encryption keys (if an encryption key is included, two
#     cases) and the ServicePrincipal refusals with conditions. This tool
#     grants to identities, so a service principal is simply not a grant
#     target here; Grant.add_to_principal refuses what cannot carry a
#     statement, which the unit tests pin.
#   - the replica-handler permission cases. No replicas here.
#
# Parity: 166 cases in the origin; 12 ported; 154 not ported.

require "test_helper"
require "support/cdk_constructs"

class CdkConstructsTableTest < CdkConstructs::TestCase
  # The origin's shared shape, under this tool's defaults (see the header).
  DEFAULT_TABLE_PROPERTIES = {
    "AttributeDefinitions" => [
      { "AttributeName" => "hashKey", "AttributeType" => "S" },
      { "AttributeName" => "sortKey", "AttributeType" => "N" }
    ],
    "KeySchema" => [
      { "AttributeName" => "hashKey", "KeyType" => "HASH" },
      { "AttributeName" => "sortKey", "KeyType" => "RANGE" }
    ],
    "BillingMode" => "PAY_PER_REQUEST",
    "PointInTimeRecoverySpecification" => { "PointInTimeRecoveryEnabled" => true }
  }.freeze

  def test_hash_key_only
    built = stack do
      RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "hashKey", type: "S" })
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", {
      "AttributeDefinitions" => [ { "AttributeName" => "hashKey", "AttributeType" => "S" } ],
      "KeySchema" => [ { "AttributeName" => "hashKey", "KeyType" => "HASH" } ],
      "BillingMode" => "PAY_PER_REQUEST",
      "PointInTimeRecoverySpecification" => { "PointInTimeRecoveryEnabled" => true }
    })

    template(built).has_resource("AWS::DynamoDB::Table", {
      "DeletionPolicy" => "RetainExceptOnCreate",
      "UpdateReplacePolicy" => "Retain"
    })
  end

  def test_table_without_indexes_omits_gsi_and_lsi_properties
    built = stack do
      RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "hashKey", type: "S" })
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", {
      "GlobalSecondaryIndexes" => RubyCdk::Test.absent(),
      "LocalSecondaryIndexes" => RubyCdk::Test.absent()
    })
  end

  def test_hash_plus_range_key
    built = stack do
      RubyCdk::DynamoDB::Table.new(self, "Table",
        partition_key: { name: "hashKey", type: "S" },
        sort_key: { name: "sortKey", type: "N" })
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", DEFAULT_TABLE_PROPERTIES)
  end

  def test_point_in_time_recovery_is_not_enabled
    # Changed: here the default table carries point-in-time recovery on; the
    # case pins the rest of the default shape (see the header).
    built = stack do
      RubyCdk::DynamoDB::Table.new(self, "Table",
        partition_key: { name: "hashKey", type: "S" },
        sort_key: { name: "sortKey", type: "N" })
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", DEFAULT_TABLE_PROPERTIES)
  end

  def test_stream_is_not_enabled
    built = stack do
      RubyCdk::DynamoDB::Table.new(self, "Table",
        partition_key: { name: "hashKey", type: "S" },
        sort_key: { name: "sortKey", type: "N" })
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", {
      "StreamSpecification" => RubyCdk::Test.absent()
    })
  end

  def test_ttl_is_not_enabled
    built = stack do
      RubyCdk::DynamoDB::Table.new(self, "Table",
        partition_key: { name: "hashKey", type: "S" },
        sort_key: { name: "sortKey", type: "N" })
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", {
      "TimeToLiveSpecification" => RubyCdk::Test.absent()
    })
  end

  def test_when_specifying_no_table_class
    built = stack do
      RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "hashKey", type: "S" })
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", {
      "TableClass" => RubyCdk::Test.absent()
    })
  end

  def test_when_specifying_pay_per_request_billing_mode
    built = stack do
      RubyCdk::DynamoDB::Table.new(self, "Table",
        table_name: "MyTable",
        billing: :on_demand,
        partition_key: { name: "hashKey", type: "S" })
    end

    template(built).has_resource_properties("AWS::DynamoDB::Table", {
      "KeySchema" => [ { "AttributeName" => "hashKey", "KeyType" => "HASH" } ],
      "BillingMode" => "PAY_PER_REQUEST",
      "AttributeDefinitions" => [ { "AttributeName" => "hashKey", "AttributeType" => "S" } ],
      "TableName" => "MyTable"
    })
  end

  def test_grant_allows_adding_arbitrary_actions_associated_with_this_table_resource
    built = stack do
      table = RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "hashKey", type: "S" })
      user = RubyCdk::IAM::Role.new(self, "user", assumed_by: "sns.amazonaws.com")
      table.grant(user, "dynamodb:action1", "dynamodb:action2")
    end

    grant_statement(template(built), [ "dynamodb:action1", "dynamodb:action2" ])
  end

  def test_grant_read_data_allows_the_principal_to_read_data_from_the_table
    built = stack do
      table = RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "hashKey", type: "S" })
      user = RubyCdk::IAM::Role.new(self, "user", assumed_by: "sns.amazonaws.com")
      table.grant_read_data(user)
    end

    grant_statement(template(built), [
      "dynamodb:BatchGetItem", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:Query",
      "dynamodb:GetItem", "dynamodb:Scan", "dynamodb:ConditionCheckItem", "dynamodb:DescribeTable"
    ])
  end

  def test_grant_read_write_data_allows_the_principal_to_read_write_data
    built = stack do
      table = RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "hashKey", type: "S" })
      user = RubyCdk::IAM::Role.new(self, "user", assumed_by: "sns.amazonaws.com")
      table.grant_read_write_data(user)
    end

    grant_statement(template(built), [
      "dynamodb:BatchGetItem", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:Query",
      "dynamodb:GetItem", "dynamodb:Scan", "dynamodb:ConditionCheckItem",
      "dynamodb:BatchWriteItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem",
      "dynamodb:DescribeTable"
    ])
  end

  def test_grant_full_access_allows_the_principal_to_perform_any_action_on_the_table
    built = stack do
      table = RubyCdk::DynamoDB::Table.new(self, "Table", partition_key: { name: "hashKey", type: "S" })
      user = RubyCdk::IAM::Role.new(self, "user", assumed_by: "sns.amazonaws.com")
      table.grant_full_access(user)
    end

    grant_statement(template(built), "dynamodb:*")
  end

  private

  # The origin's testGrant: the statement the principal's policy carries, the
  # table ARN as its resource. One statement here, where the CDK's policy
  # document minimizes its two into this one.
  def grant_statement(template, actions)
    template.has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ {
          "Action" => actions,
          "Effect" => "Allow",
          "Resource" => { "Fn::GetAtt" => [ "TableResource", "Arn" ] }
        } ],
        "Version" => "2012-10-17"
      },
      "Roles" => [ { "Ref" => "userResource" } ]
    })
  end
end
