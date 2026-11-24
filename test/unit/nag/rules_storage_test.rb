# frozen_string_literal: true

require "test_helper"
require "support/nag_case"

# The rules over data at rest: RC-S3-001, RC-DYNAMODB-001, RC-EBS-001,
# RC-RDS-001, RC-STATE-001, RC-LOGS-001. Each with a passing, a failing and a
# suppressed case, and with what it does when a value is dynamic.
class NagRulesStorageTest < Minitest::Test
  include NagCase

  BUCKET = "AWS::S3::Bucket"
  TABLE = "AWS::DynamoDB::Table"
  VOLUME = "AWS::EC2::Volume"
  DB_INSTANCE = "AWS::RDS::DBInstance"
  DB_CLUSTER = "AWS::RDS::DBCluster"
  LOG_GROUP = "AWS::Logs::LogGroup"
  ALL_ON = { "BlockPublicAcls" => true, "IgnorePublicAcls" => true, "BlockPublicPolicy" => true, "RestrictPublicBuckets" => true }.freeze
  NO_VALUE = { "Ref" => "AWS::NoValue" }.freeze
  REASON = "The bucket is a public website; reviewed on 2026-11-23."

  # --- RC-S3-001: the four public access block settings

  def test_s3_public_access_block_passes_when_the_four_settings_are_true
    assert_clean check_resource(BUCKET, { "PublicAccessBlockConfiguration" => ALL_ON })
  end

  def test_s3_public_access_block_passes_when_the_settings_are_written_as_their_names
    # Templates written before the schema was strict carry booleans as strings.
    assert_clean check_resource(BUCKET, { "PublicAccessBlockConfiguration" => ALL_ON.transform_values { "true" } })
  end

  def test_s3_public_access_block_fails_when_the_configuration_is_absent
    report = check_resource(BUCKET, { "BucketName" => "data" })

    assert_one_violation(report, "RC-S3-001", severity: :high, resource_type: BUCKET, path: "Properties.PublicAccessBlockConfiguration",
      says: [ "PublicAccessBlockConfiguration", "BlockPublicAcls", "RestrictPublicBuckets" ])
    assert report.fails?(:high)
  end

  def test_s3_public_access_block_fails_when_the_configuration_is_aws_no_value
    # {"Ref" => "AWS::NoValue"} removes the property: the bucket has no configuration at all.
    assert_equal [ "Only" ], hits(check_resource(BUCKET, { "PublicAccessBlockConfiguration" => NO_VALUE }), "RC-S3-001")
  end

  def test_s3_public_access_block_fails_and_names_the_settings_that_are_off
    false_one = check_resource(BUCKET, { "PublicAccessBlockConfiguration" => ALL_ON.merge("BlockPublicPolicy" => false) })
    absent_one = check_resource(BUCKET, { "PublicAccessBlockConfiguration" => ALL_ON.except("IgnorePublicAcls") })
    both = check_resource(BUCKET, { "PublicAccessBlockConfiguration" => { "BlockPublicAcls" => true } })

    assert_one_violation(false_one, "RC-S3-001", severity: :high, resource_type: BUCKET, path: "Properties.PublicAccessBlockConfiguration", says: [ "BlockPublicPolicy is not true" ])
    assert_one_violation(absent_one, "RC-S3-001", severity: :high, resource_type: BUCKET, path: "Properties.PublicAccessBlockConfiguration", says: [ "IgnorePublicAcls is not true" ])
    assert_one_violation(both, "RC-S3-001", severity: :high, resource_type: BUCKET, path: "Properties.PublicAccessBlockConfiguration",
      says: [ "IgnorePublicAcls, BlockPublicPolicy, RestrictPublicBuckets are not true" ])
  end

  def test_s3_public_access_block_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(BUCKET, {}, **rules_to_suppress({ "Id" => "RC-S3-001", "Reason" => REASON }))

    assert_suppressed(report, "RC-S3-001", reason: REASON)
  end

  def test_s3_public_access_block_counts_a_dynamic_configuration_and_decides_nothing
    report = check_resource(BUCKET, { "PublicAccessBlockConfiguration" => { "Fn::If" => [ "IsPublic", NO_VALUE, ALL_ON ] } })

    assert_undecided(report, "RC-S3-001", path: "Properties.PublicAccessBlockConfiguration")
  end

  def test_s3_public_access_block_decides_the_other_settings_when_one_is_dynamic
    configuration = ALL_ON.merge("IgnorePublicAcls" => { "Ref" => "IgnoreAcls" }, "BlockPublicPolicy" => false)
    report = check_resource(BUCKET, { "PublicAccessBlockConfiguration" => configuration })

    # The setting that is false is a finding on its own; the one that is a Ref is left undecided.
    assert_one_violation(report, "RC-S3-001", severity: :high, resource_type: BUCKET, path: "Properties.PublicAccessBlockConfiguration", says: [ "BlockPublicPolicy is not true" ])
    assert_equal [ "Properties.PublicAccessBlockConfiguration.IgnorePublicAcls" ], undecided(report, "RC-S3-001")
  end

  # --- RC-DYNAMODB-001: point-in-time recovery

  def test_dynamodb_point_in_time_recovery_passes_when_it_is_enabled
    assert_clean check_resource(TABLE, { "PointInTimeRecoverySpecification" => { "PointInTimeRecoveryEnabled" => true } })
  end

  def test_dynamodb_point_in_time_recovery_fails_when_it_is_not_enabled
    absent = check_resource(TABLE, { "TableName" => "t" })
    disabled = check_resource(TABLE, { "PointInTimeRecoverySpecification" => { "PointInTimeRecoveryEnabled" => false } })
    written_as_a_string = check_resource(TABLE, { "PointInTimeRecoverySpecification" => { "PointInTimeRecoveryEnabled" => "false" } })
    empty_specification = check_resource(TABLE, { "PointInTimeRecoverySpecification" => {} })

    [ absent, disabled, written_as_a_string, empty_specification ].each do |report|
      assert_one_violation(report, "RC-DYNAMODB-001", severity: :medium, resource_type: TABLE, path: "Properties.PointInTimeRecoverySpecification",
        says: [ "PointInTimeRecoverySpecification.PointInTimeRecoveryEnabled to true" ])
      assert report.fails?(:medium)
      refute report.fails?(:high)
    end
  end

  def test_dynamodb_point_in_time_recovery_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(TABLE, {}, **rules_to_suppress({ "Id" => "RC-DYNAMODB-001", "Reason" => "A throwaway table." }))

    assert_suppressed(report, "RC-DYNAMODB-001", reason: "A throwaway table.")
  end

  def test_dynamodb_point_in_time_recovery_counts_a_dynamic_value
    flag = check_resource(TABLE, { "PointInTimeRecoverySpecification" => { "PointInTimeRecoveryEnabled" => { "Ref" => "EnablePitr" } } })
    specification = check_resource(TABLE, { "PointInTimeRecoverySpecification" => { "Fn::If" => [ "Prod", { "PointInTimeRecoveryEnabled" => true }, NO_VALUE ] } })

    assert_undecided(flag, "RC-DYNAMODB-001", path: "Properties.PointInTimeRecoverySpecification.PointInTimeRecoveryEnabled")
    assert_undecided(specification, "RC-DYNAMODB-001", path: "Properties.PointInTimeRecoverySpecification")
  end

  # --- RC-EBS-001: an encrypted volume

  def test_ebs_volume_passes_when_it_is_encrypted
    assert_clean check_resource(VOLUME, { "Encrypted" => true })
    assert_clean check_resource(VOLUME, { "Encrypted" => "true", "KmsKeyId" => NO_VALUE })
  end

  def test_ebs_volume_fails_when_it_is_not_encrypted
    absent = check_resource(VOLUME, { "Size" => 100 })
    false_one = check_resource(VOLUME, { "Encrypted" => false })
    written_as_a_string = check_resource(VOLUME, { "Encrypted" => "false" })

    [ absent, false_one, written_as_a_string ].each do |report|
      assert_one_violation(report, "RC-EBS-001", severity: :high, resource_type: VOLUME, path: "Properties.Encrypted", says: [ "set Encrypted to true" ])
    end
  end

  def test_ebs_volume_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(VOLUME, {}, **rules_to_suppress({ "Id" => "RC-EBS-001", "Reason" => "Scratch disk." }))

    assert_suppressed(report, "RC-EBS-001", reason: "Scratch disk.")
  end

  def test_ebs_volume_counts_a_dynamic_value
    report = check_resource(VOLUME, { "Encrypted" => { "Ref" => "Encrypt" } })

    assert_undecided(report, "RC-EBS-001", path: "Properties.Encrypted")
  end

  # --- RC-RDS-001: encrypted storage

  def test_rds_storage_passes_when_it_is_encrypted
    assert_clean check_resource(DB_INSTANCE, { "Engine" => "mysql", "StorageEncrypted" => "true" })
    assert_clean check_resource(DB_CLUSTER, { "Engine" => "aurora-mysql", "StorageEncrypted" => true })
  end

  def test_rds_storage_fails_when_it_is_not_encrypted
    instance = check_resource(DB_INSTANCE, { "Engine" => "mysql", "StorageEncrypted" => false })
    cluster = check_resource(DB_CLUSTER, { "Engine" => "aurora-postgresql" })

    assert_one_violation(instance, "RC-RDS-001", severity: :high, resource_type: DB_INSTANCE, path: "Properties.StorageEncrypted", says: [ "StorageEncrypted" ])
    assert_one_violation(cluster, "RC-RDS-001", severity: :high, resource_type: DB_CLUSTER, path: "Properties.StorageEncrypted", says: [ "StorageEncrypted" ])
  end

  def test_rds_storage_passes_an_aurora_instance_whose_cluster_carries_the_encryption
    # cdk-nag RDSStorageEncrypted: an instance whose Engine holds "aurora" takes it from its cluster.
    assert_clean check_resource(DB_INSTANCE, { "Engine" => "Aurora", "StorageEncrypted" => false })
  end

  def test_rds_storage_passes_a_member_of_a_cluster_whose_engine_is_not_aurora
    # cfn-nag F27: an instance that names a DBClusterIdentifier is a member of that cluster,
    # as the members of a Multi-AZ DB cluster are.
    assert_clean check_resource(DB_INSTANCE, { "Engine" => "postgres", "DBClusterIdentifier" => "cluster" })
  end

  def test_rds_storage_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(DB_CLUSTER, {}, **rules_to_suppress({ "Id" => "RC-RDS-001", "Reason" => "Empty test cluster." }))

    assert_suppressed(report, "RC-RDS-001", reason: "Empty test cluster.")
  end

  def test_rds_storage_counts_a_dynamic_value
    report = check_resource(DB_INSTANCE, { "Engine" => "mysql", "StorageEncrypted" => { "Ref" => "Encrypt" } })

    assert_undecided(report, "RC-RDS-001", path: "Properties.StorageEncrypted")
  end

  def test_rds_storage_reports_an_unencrypted_instance_whose_engine_is_dynamic
    report = check_resource(DB_INSTANCE, { "Engine" => { "Ref" => "Engine" } })

    # Whether it is an Aurora instance cannot be read, so that exemption is left undecided; the storage is still not encrypted.
    assert_one_violation(report, "RC-RDS-001", severity: :high, resource_type: DB_INSTANCE, path: "Properties.StorageEncrypted", says: [ "StorageEncrypted" ])
    assert_equal [ "Properties.Engine" ], undecided(report, "RC-RDS-001")
  end

  # --- RC-STATE-001: a stateful resource is not deleted

  def test_stateful_deletion_passes_when_the_resource_is_retained_snapshotted_or_left_to_synthesis
    policies = [ "Retain", "RetainExceptOnCreate", "Snapshot" ]

    policies.each do |policy|
      report = check_resource(BUCKET, {}, deletion_policy: policy)

      assert_empty violations(report, "RC-STATE-001"), policy
    end
    report = check_resource(BUCKET, { "BucketName" => "kept-by-the-default" })

    assert_empty violations(report, "RC-STATE-001"), "no written policy is synthesis's business, not this rule's"
  end

  def test_stateful_deletion_fails_for_every_type_of_the_default_list
    RubyCdk::Nag::STATEFUL_TYPES.each do |type|
      report = check_resource(type, {}, deletion_policy: "Delete")

      assert_one_violation(report, "RC-STATE-001", severity: :high, resource_type: type, path: "DeletionPolicy", says: [ "DeletionPolicy Delete" ])
    end
  end

  def test_stateful_deletion_leaves_a_type_that_is_not_stateful_alone
    assert_clean check_resource("AWS::Lambda::Function", { "Runtime" => "ruby4.0" }, deletion_policy: "Delete")
  end

  def test_stateful_deletion_reads_the_list_the_configuration_gives
    config = { "stateful_types" => [ "AWS::Example::Thing" ] }
    thing = check_resource("AWS::Example::Thing", {}, config: config, deletion_policy: "Delete")
    bucket = check_resource(BUCKET, { "PublicAccessBlockConfiguration" => ALL_ON }, config: config, deletion_policy: "Delete")

    assert_one_violation(thing, "RC-STATE-001", severity: :high, resource_type: "AWS::Example::Thing", path: "DeletionPolicy", says: [ "DeletionPolicy Delete" ])
    assert_empty violations(bucket, "RC-STATE-001"), "a bucket is not stateful under this configuration"
  end

  def test_stateful_deletion_is_suppressed_when_the_resource_says_so_with_a_reason
    # The recovery keeps the other rules of the pack out of the way: this test is about the suppression.
    kept = { "PointInTimeRecoverySpecification" => { "PointInTimeRecoveryEnabled" => true } }
    report = check_resource(TABLE, kept, deletion_policy: "Delete", **rules_to_suppress({ "Id" => "RC-STATE-001", "Reason" => "Recreated from the fixture every night." }))

    assert_suppressed(report, "RC-STATE-001", reason: "Recreated from the fixture every night.")
  end

  def test_stateful_deletion_counts_a_dynamic_policy
    report = check_resource(BUCKET, {}, deletion_policy: { "Fn::If" => [ "IsSandbox", "Delete", "RetainExceptOnCreate" ] })

    assert_undecided(report, "RC-STATE-001", path: "DeletionPolicy")
  end

  # --- RC-LOGS-001: a retention period

  def test_log_group_passes_when_a_retention_is_set
    assert_clean check_resource(LOG_GROUP, { "RetentionInDays" => 7 })
    assert_clean check_resource(LOG_GROUP, { "RetentionInDays" => "30" })
  end

  def test_log_group_fails_when_no_retention_is_set
    report = check_resource(LOG_GROUP, { "LogGroupName" => "/aws/lambda/fn" })

    assert_one_violation(report, "RC-LOGS-001", severity: :low, resource_type: LOG_GROUP, path: "Properties.RetentionInDays", says: [ "RetentionInDays" ])
    assert report.fails?(:low)
    refute report.fails?(:medium)
  end

  def test_log_group_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(LOG_GROUP, {}, **rules_to_suppress({ "Id" => "RC-LOGS-001", "Reason" => "Kept for the audit." }))

    assert_suppressed(report, "RC-LOGS-001", reason: "Kept for the audit.")
  end

  def test_log_group_counts_a_dynamic_retention
    report = check_resource(LOG_GROUP, { "RetentionInDays" => { "Ref" => "Retention" } })

    assert_undecided(report, "RC-LOGS-001", path: "Properties.RetentionInDays")
  end
end
