# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# Architecture §7: the types the CDK retains are retained here, and the two policies are written per resource type.
class CoreStatefulTest < CoreHelpers::TestCase
  def test_the_types_the_cdk_retains_are_the_types_retained_here
    %w[
      AWS::S3::Bucket AWS::DynamoDB::Table AWS::Logs::LogGroup AWS::Logs::LogStream AWS::KMS::Key
      AWS::EC2::Volume AWS::ECR::Repository AWS::Cognito::UserPool AWS::Kinesis::Stream
      AWS::OpenSearchService::Domain AWS::Elasticsearch::Domain AWS::Glue::Database
      AWS::Backup::BackupVault AWS::CodeBuild::ReportGroup AWS::Scheduler::ScheduleGroup
      AWS::DocDB::DBCluster AWS::DocDB::DBInstance AWS::FSx::FileSystem
      AWS::AppConfig::HostedConfigurationVersion
    ].each do |type|
      assert_equal %w[ RetainExceptOnCreate Retain ], RubyCdk::Core::Stateful.policies_for(type, default: :retain_except_on_create), type
    end

    %w[ AWS::RDS::DBInstance AWS::RDS::DBCluster ].each do |type|
      assert_equal %w[ Snapshot Snapshot ], RubyCdk::Core::Stateful.policies_for(type, default: :retain_except_on_create), type
    end
  end

  def test_what_the_cdk_deletes_gets_no_policy
    %w[
      AWS::SQS::Queue AWS::SNS::Topic AWS::SecretsManager::Secret AWS::Lambda::Function AWS::IAM::Role
      AWS::EFS::FileSystem AWS::Route53::HostedZone AWS::Redshift::Cluster AWS::ElastiCache::CacheCluster
      AWS::S3::BucketPolicy AWS::DynamoDB::GlobalTable AWS::KMS::Alias AWS::Cognito::UserPoolClient
      AWS::RDS::DBSubnetGroup AWS::RDS::DBParameterGroup AWS::Logs::SubscriptionFilter Custom::Thing
      AWS::ApiGateway::Deployment
    ].each do |type|
      assert_nil RubyCdk::Core::Stateful.policies_for(type, default: :retain_except_on_create), type
      refute RubyCdk::Core::Stateful.stateful?(type), type
    end
  end

  def test_subresources_that_only_attach_configuration_are_never_stateful
    assert RubyCdk::Core::Stateful.stateful?("AWS::S3::Bucket")
    refute RubyCdk::Core::Stateful.stateful?("AWS::S3::BucketPolicy")
    assert RubyCdk::Core::Stateful.stateful?("AWS::EC2::Volume")
    refute RubyCdk::Core::Stateful.stateful?("AWS::EC2::VolumeAttachment")
  end

  def test_with_stateful_delete_every_stateful_type_is_written_out_as_deleted_as_a_destroy_policy_is
    %w[ AWS::S3::Bucket AWS::RDS::DBInstance AWS::RDS::DBCluster AWS::DynamoDB::Table ].each do |type|
      assert_equal %w[ Delete Delete ], RubyCdk::Core::Stateful.policies_for(type, default: :delete), type
    end
    assert_nil RubyCdk::Core::Stateful.policies_for("AWS::Lambda::Function", default: :delete)
  end

  def test_one_deletion_policy_sets_both_attributes_as_the_cdk_s_removal_policy_does
    assert_equal %w[ Delete Delete ], RubyCdk::Core::Stateful.pair("Delete")
    assert_equal %w[ Retain Retain ], RubyCdk::Core::Stateful.pair("Retain")
    assert_equal %w[ RetainExceptOnCreate Retain ], RubyCdk::Core::Stateful.pair("RetainExceptOnCreate")
    assert_equal %w[ Snapshot Snapshot ], RubyCdk::Core::Stateful.pair("Snapshot")
    assert_raises(KeyError) { RubyCdk::Core::Stateful.pair("Retainn") }
  end

  def test_a_policy_is_a_symbol_or_cloudformation_s_name
    assert_equal "Delete", RubyCdk::Core::Stateful.deletion_policy(:delete)
    assert_equal "Retain", RubyCdk::Core::Stateful.deletion_policy("Retain")
    assert_equal "RetainExceptOnCreate", RubyCdk::Core::Stateful.deletion_policy(:retain_except_on_create)
    assert_equal "Snapshot", RubyCdk::Core::Stateful.deletion_policy(:snapshot)
    assert_nil RubyCdk::Core::Stateful.deletion_policy(nil)

    assert_equal "Delete", RubyCdk::Core::Stateful.update_replace_policy(:delete)
    assert_equal "Retain", RubyCdk::Core::Stateful.update_replace_policy("Retain")
    assert_equal "Snapshot", RubyCdk::Core::Stateful.update_replace_policy(:snapshot)
    assert_nil RubyCdk::Core::Stateful.update_replace_policy(nil)
  end

  def test_anything_else_is_a_usage_error_and_update_replace_policy_takes_no_retain_except_on_create
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Core::Stateful.deletion_policy(:retainn) }

    assert_equal "deletion_policy: :retainn is not one of Delete, Retain, RetainExceptOnCreate, Snapshot", error.message

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Core::Stateful.update_replace_policy(:retain_except_on_create) }

    assert_equal "update_replace_policy: :retain_except_on_create is not one of Delete, Retain, Snapshot", error.message
    assert_raises(RubyCdk::UsageError) { RubyCdk::Core::Stateful.deletion_policy("delete") }
  end
end
