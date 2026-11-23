# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# Architecture §7 at render: what a resource gets when the user said nothing,
# and what the two keywords change.
class SynthRetentionTest < CoreHelpers::TestCase
  RETAINED = {
    "Bucket" => "AWS::S3::Bucket", "Table" => "AWS::DynamoDB::Table", "LogGroup" => "AWS::Logs::LogGroup",
    "Key" => "AWS::KMS::Key", "Volume" => "AWS::EC2::Volume", "Repository" => "AWS::ECR::Repository",
    "UserPool" => "AWS::Cognito::UserPool", "Stream" => "AWS::Kinesis::Stream", "Domain" => "AWS::OpenSearchService::Domain"
  }.freeze

  SNAPSHOTTED = { "DBInstance" => "AWS::RDS::DBInstance", "DBCluster" => "AWS::RDS::DBCluster" }.freeze

  DELETED = {
    "Queue" => "AWS::SQS::Queue", "Topic" => "AWS::SNS::Topic", "Secret" => "AWS::SecretsManager::Secret",
    "Function" => "AWS::Lambda::Function", "Role" => "AWS::IAM::Role", "FileSystem" => "AWS::EFS::FileSystem",
    "HostedZone" => "AWS::Route53::HostedZone", "Redshift" => "AWS::Redshift::Cluster", "Cache" => "AWS::ElastiCache::CacheCluster"
  }.freeze

  def policies_of(body)
    [ body["DeletionPolicy"], body["UpdateReplacePolicy"] ]
  end

  def test_the_types_the_cdk_retains_get_retain_except_on_create_and_retain
    stack = build_stack { RETAINED.each { |id, type| resource(id, type) } }
    resources = stack.to_template["Resources"]

    RETAINED.each_key do |id|
      assert_equal %w[ RetainExceptOnCreate Retain ], policies_of(resources[id]), id
    end
    assert_equal [ "Type", "DeletionPolicy", "UpdateReplacePolicy" ], resources["Bucket"].keys
  end

  def test_the_rds_types_get_snapshot_for_both
    stack = build_stack { SNAPSHOTTED.each { |id, type| resource(id, type) } }
    resources = stack.to_template["Resources"]

    SNAPSHOTTED.each_key do |id|
      assert_equal %w[ Snapshot Snapshot ], policies_of(resources[id]), id
    end
  end

  def test_everything_else_is_deleted_as_in_the_cdk_so_nothing_is_written
    stack = build_stack { DELETED.each { |id, type| resource(id, type) } }
    resources = stack.to_template["Resources"]

    DELETED.each_key do |id|
      assert_equal [ nil, nil ], policies_of(resources[id]), id
      assert_equal [ "Type" ], resources[id].keys, id
    end
  end

  def test_a_subresource_that_only_attaches_configuration_is_not_stateful
    stack = build_stack do
      resource("BucketPolicy", "AWS::S3::BucketPolicy")
      resource("Table", "AWS::DynamoDB::Table")
      resource("Custom", "Custom::Thing")
    end
    resources = stack.to_template["Resources"]

    assert_equal [ "Type" ], resources["BucketPolicy"].keys
    assert_equal %w[ RetainExceptOnCreate Retain ], policies_of(resources["Table"])
    assert_equal [ "Type" ], resources["Custom"].keys
  end

  def test_deletion_policy_is_the_removal_policy_and_sets_both_attributes
    stack = build_stack do
      @destroyed = resource("Bucket", "AWS::S3::Bucket", deletion_policy: :delete)
      @kept = resource("Table", "AWS::DynamoDB::Table", deletion_policy: :retain)
      @except = resource("Queue", "AWS::SQS::Queue", deletion_policy: :retain_except_on_create)
      @snap = resource("Function", "AWS::Lambda::Function", deletion_policy: "Snapshot")
    end
    resources = stack.to_template["Resources"]

    assert_equal %w[ Delete Delete ], policies_of(resources["Bucket"])
    assert_equal %w[ Retain Retain ], policies_of(resources["Table"])
    assert_equal %w[ RetainExceptOnCreate Retain ], policies_of(resources["Queue"])
    assert_equal %w[ Snapshot Snapshot ], policies_of(resources["Function"])
    assert_nil stack.instance_variable_get(:@destroyed).update_replace_policy
  end

  def test_update_replace_policy_replaces_the_second_attribute_alone
    stack = build_stack do
      resource("Bucket", "AWS::S3::Bucket", update_replace_policy: :delete)
      resource("Table", "AWS::DynamoDB::Table", deletion_policy: :delete, update_replace_policy: :retain)
      resource("Queue", "AWS::SQS::Queue", update_replace_policy: "Retain")
      resource("Db", "AWS::RDS::DBInstance", update_replace_policy: :retain)
    end
    resources = stack.to_template["Resources"]

    assert_equal %w[ RetainExceptOnCreate Delete ], policies_of(resources["Bucket"])
    assert_equal %w[ Delete Retain ], policies_of(resources["Table"])
    assert_equal [ nil, "Retain" ], policies_of(resources["Queue"])
    assert_equal %w[ Snapshot Retain ], policies_of(resources["Db"])
  end

  def test_stateful_delete_on_the_stack_or_the_app_deletes_every_stateful_type
    stack = build_stack(stack_options: { stateful_default: :delete }) do
      resource("Bucket", "AWS::S3::Bucket")
      resource("Db", "AWS::RDS::DBInstance")
      resource("Queue", "AWS::SQS::Queue")
    end
    resources = stack.to_template["Resources"]

    assert_equal %w[ Delete Delete ], policies_of(resources["Bucket"])
    assert_equal %w[ Delete Delete ], policies_of(resources["Db"])
    assert_equal [ "Type" ], resources["Queue"].keys

    from_app = build_stack(app_options: { stateful_default: :delete }) { resource("Bucket", "AWS::S3::Bucket") }
    assert_equal %w[ Delete Delete ], policies_of(from_app.to_template["Resources"]["Bucket"])

    kept = build_stack(app_options: { stateful_default: :delete }, stack_options: { stateful_default: :retain_except_on_create }) do
      resource("Bucket", "AWS::S3::Bucket")
    end
    assert_equal %w[ RetainExceptOnCreate Retain ], policies_of(kept.to_template["Resources"]["Bucket"])
  end

  def test_a_policy_given_on_the_resource_wins_over_a_stack_that_deletes
    stack = build_stack(stack_options: { stateful_default: :delete }) do
      resource("Bucket", "AWS::S3::Bucket", deletion_policy: :retain)
    end

    assert_equal %w[ Retain Retain ], policies_of(stack.to_template["Resources"]["Bucket"])
  end
end
