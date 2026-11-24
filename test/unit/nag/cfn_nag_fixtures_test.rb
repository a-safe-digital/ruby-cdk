# frozen_string_literal: true

require "test_helper"
require "support/nag_case"
require "support/nag_template"
require "digest"

# The cfn-nag fixtures, with the expectation each one was given by reading the
# template (test/fixtures/nag/README.md says where every file comes from and
# how it was chosen).
#
# The scoreboard at the end is the row of docs/07-testing.md section 11:
# "Security rules: cfn-nag fixtures that hit and do not hit, per rule".
class NagCfnNagFixturesTest < Minitest::Test
  include NagCase

  FIXTURES = File.expand_path("../../fixtures/nag", __dir__)

  # Every fixture of the pack that finds or leaves something, and what. One
  # line per file, with the reason the template was given that expectation.
  # A file that is not here is clean: nothing found, nothing left undecided.
  EXPECTED = {
    # The inline rule is written as one object, the way CloudFormation allows for a list of one.
    "json/security_group/security_group_open_to_world_on_ingress.json" => { "RC-EC2-001" => %w[sgOpenIngress securityGroupIngress] },
    "json/security_group/standalone_ingress_open_to_world.json" => { "RC-EC2-001" => %w[securityGroupIngress] },
    "json/security_group/single_security_group_empty_ingress.json" => {},
    "json/security_group/single_security_group_one_cidr_ingress.json" => {},
    # Three rules carry a Ref or a list where a CIDR belongs: left undecided, never reported.
    "json/security_group/non_32_cidr_standalone_ingress.json" => { skip: { "RC-EC2-001" => 3, "RC-EC2-002" => 3 } },
    # Three SSH rules open to the world: one written 0000:...:0000/0 in full, one 0000::/0, one ::/0 unquoted.
    "yaml/security_group/ip6_security_groups_open_to_world.yml" => { "RC-EC2-001" => %w[InstanceSecurityGroup InstanceSecurityGroup2 InstanceSecurityGroup3 securityGroupIngress] },
    "yaml/security_group/security_group_rule_description_pass.yml" => {},
    "yaml/security_group/bad_cidr_in_parameter.yml" => { skip: { "RC-EC2-001" => 1, "RC-EC2-002" => 1 } },
    # The open rule is on the egress list and inside an Fn::If: not an ingress finding, and not readable.
    "yaml/security_group/pesky_if.yml" => {},
    # cfn_nag's own suppression metadata is not this tool's: nothing is suppressed here.
    "yaml/security_group/sg_with_suppression.yml" => { "RC-EC2-001" => %w[securityGroupIngress securityGroupIngress2] },
    # Three buckets without the block; the third policy denies to a wildcard principal under a condition.
    "json/s3_bucket_policy/s3_bucket_with_wildcards.json" => { "RC-S3-001" => %w[S3Bucket S3Bucket2 S3Bucket3], "RC-POLICY-001" => %w[S3BucketPolicy2] },
    "json/s3_bucket_policy/s3_bucket_policy_with_not_action.json" => { "RC-S3-001" => %w[S3Bucket] },
    # Policies 1 to 1d grant to a named user; 2, 2b and 2c grant to * (one written as one object).
    "json/sqs_queue_policy/sqs_queue_with_wildcards.json" => { "RC-POLICY-001" => %w[mysqspolicy2 mysqspolicy2b mysqspolicy2c] },
    "json/sqs_queue_policy/sqs_policy_with_not_action.json" => {},
    # 0 and 1 grant to * (one as one object), 2 through AWS: "*", 3 among a CanonicalUser.
    "json/sns_topic_policy/sns_topic_with_wildcard_principal.json" => { "RC-POLICY-001" => %w[mysnspolicy0 mysnspolicy1 mysnspolicy2 mysnspolicy3] },
    "json/sns_topic_policy/sns_topic_with_not_action.json" => {},
    # The third statement of the key policy allows the use of the key to "*".
    "yaml/kms/kms_key_with_wildcard_principal.yml" => { "RC-POLICY-001" => %w[myKeyWildcardPrincipal] },
    "yaml/kms/kms_key_without_wildcard_principal.yml" => {},
    "json/s3_bucket/buckets_with_access_logging.json" => { "RC-S3-001" => %w[S3BucketNoAccessLogging] },
    "yaml/s3/bucket_with_no_policy.yml" => { "RC-S3-001" => %w[Bucket Bucket2] },
    # The policy's first Allow takes its principal from a Ref: left undecided.
    "yaml/s3/bucket_with_non_literal_policy.yml" => { "RC-S3-001" => %w[S3Bucket], skip: { "RC-POLICY-001" => 1 } },
    # The role's inline policy grants s3:*; the bucket is blocked on all four settings.
    "yaml/gamelift/support_resources.yml" => { "RC-IAM-002" => %w[IamRole] },
    # The action list holds an Fn::Join, so neither IAM rule can read it: left undecided.
    "json/iam_policy/iam_policy_with_wildcard_action.json" => { skip: { "RC-IAM-001" => 1, "RC-IAM-002" => 1 } },
    "json/iam_policy/iam_policy_with_wildcard_resource.json" => {},
    "json/iam_managed_policy/iam_managed_policy_with_wildcard_action.json" => { "RC-IAM-002" => %w[CreateTestDBPolicy3] },
    # One statement: Action "*" on Resource "*".
    "json/iam_role/iam_role.json" => { "RC-IAM-001" => %w[RootRole], "RC-IAM-002" => %w[RootRole] },
    # Action "*" on NotResource: a full-access finding, not an admin-access one.
    "json/iam_role/iam_role_with_wildcard_action.json" => { "RC-IAM-002" => %w[WildcardActionRole] },
    # The wildcard Action sits on the trust policy, which none of these rules reads.
    "json/iam_role/iam_role_with_wildcard_action_on_trust.json" => {},
    # The action list holds a !Sub, so the statement cannot be read: left undecided.
    "yaml/iam_role/embedded_sub.yml" => { skip: { "RC-IAM-001" => 1, "RC-IAM-002" => 1 } },
    # RoleDeny denies; RoleFail names its actions and its resources; an arn:aws:s3:::* resource is not "*".
    "yaml/iam_passrole_resource_wildcard/iam_role_passrole_resource_wildcard_pass.yml" => {},
    "json/iam_user/iam_user_with_inline_policy.json" => { "RC-IAM-003" => %w[userWithInline] },
    "json/iam_user/iam_user_with_one_group.json" => {},
    # Both functions run on nodejs6.10, which Lambda retired in 2022.
    "json/lambda_function/lambda_with_lambda_execute_managed_policy.json" => { "RC-LAMBDA-001" => %w[FunctionWithLambdaExecuteManagedPolicyRoleByRef FunctionWithLambdaExecuteManagedPolicyRoleByFnGetAtt] },
    # Four functions, four times nodejs6.10. No fixture declares an Environment, so RC-LAMBDA-002 reads nothing.
    "yaml/lambda_function/lambda_with_managed_policies.yaml" => { "RC-LAMBDA-001" => %w[FunctionWithLogsManagedPolicyRoleByRef FunctionWithLogsManagedPolicyRoleByGetAtt FunctionWithLogsManagedPolicyRoleByFnGetAtt FunctionWithOtherManagedPolicyRoleByRef] },
    # PointInTimeRecoveryEnabled: True is YAML's true.
    "yaml/dynamodb/dynamodb_table_with_backup_enabled.yaml" => {},
    # One table has it False, one has no specification at all.
    "yaml/dynamodb/dynamodb_table_with_no_backup_enabled.yaml" => { "RC-DYNAMODB-001" => %w[DynamodbNoBackupEnabled DynamodbNoBackupEnabled2] },
    # Encrypted "true", with the key left to AWS through Ref AWS::NoValue.
    "json/ec2_volume/ebs_volume_with_encryption.json" => {},
    "json/ec2_volume/ebs_volume_with_kms_key.json" => {},
    "json/ec2_volume/ebs_volume_without_encryption_string.json" => { "RC-EBS-001" => %w[NewVolumeA] },
    # The encryption flag is a Ref: left undecided.
    "json/ec2_volume/ebs_volume_without_encryption_string_externalized.json" => { skip: { "RC-EBS-001" => 1 } },
    # One volume with no Encrypted at all, one with Encrypted false.
    "json/ec2_volume/two_ebs_volumes_with_no_encryption.json" => { "RC-EBS-001" => %w[NewVolume1 NewVolume2] },
    "json/rds_instance/db_instance_with_encryption.json" => {},
    "json/rds_instance/db_instance_with_no_encryption.json" => { "RC-RDS-001" => %w[MyDB] },
    "json/rds_instance/db_instance_with_encryption_false.json" => { "RC-RDS-001" => %w[MyDB] },
    # A member of a cluster: the cluster carries the encryption, so the instance is left alone.
    "json/rds_instance/db_instance_with_clusterid_and_encryption_false.json" => {},
    "json/rds_instance/db_cluster_with_encryption.json" => {},
    # An Aurora cluster with no StorageEncrypted at all.
    "json/rds_instance/db_cluster_with_no_encryption.json" => { "RC-RDS-001" => %w[RDSCluster] },
    # NONE, None, none: all read as NONE.
    "yaml/api_gateway/api_gateway_method_authorization_type_none.yaml" => { "RC-APIGW-001" => %w[ApiGatewayMethod1 ApiGatewayMethod2 ApiGatewayMethod3] },
    # AuthorizationType with nothing after it is absent: API Gateway reads that as NONE.
    "yaml/api_gateway/api_gateway_method_authorization_type_nil_value.yaml" => { "RC-APIGW-001" => %w[ApiGatewayMethod1 ApiGatewayMethod2] },
    "yaml/api_gateway/api_gateway_method_authorization_type_none_with_param_refs.yaml" => { skip: { "RC-APIGW-001" => 3 } },
    "yaml/api_gateway/api_gateway_method_authorization_type_valid_values.yaml" => {},
    # Methods 1, 2, 5 and 6 are plain OPTIONS methods with NONE: a finding. Methods 3 and 4 take the
    # authorization type from a Ref, 5 and 6 the verb; their findings wait on a value that is not there.
    "yaml/api_gateway/api_gateway_method_with_httpmethod_options.yaml" => { "RC-APIGW-001" => %w[ApiGatewayMethod1 ApiGatewayMethod2 ApiGatewayMethod5 ApiGatewayMethod6], skip: { "RC-APIGW-001" => 4 } },
    "yaml/cloudwatchlogs_loggroup/cloudwatchlogs_loggroup_with_retention.yaml" => {},
    "yaml/cloudwatchlogs_loggroup/cloudwatchlogs_loggroup_without_retention.yaml" => { "RC-LOGS-001" => %w[CWLogGroup] }
    # No template of the corpus sets DeletionPolicy on a stateful resource, so RC-STATE-001 reads
    # every bucket, table, volume, database and log group here and reports none of them.
  }.freeze

  def test_every_stored_fixture_is_exactly_the_file_that_was_fetched
    File.readlines(File.join(FIXTURES, "sha256.txt"), chomp: true).each do |line|
      digest, path = line.split(/\s+/, 2)
      file = File.join(FIXTURES, path)

      assert File.file?(file), "#{path} is in sha256.txt and not in the tree"
      assert_equal digest, Digest::SHA256.file(file).hexdigest, "#{path} does not hold the bytes that were fetched from cfn_nag@8b5f03d"
    end
  end

  def test_every_file_in_the_tree_is_in_the_pin
    pinned = File.readlines(File.join(FIXTURES, "sha256.txt"), chomp: true).map { |line| line.split(/\s+/, 2).last }
    stored = Dir[File.join(FIXTURES, "**", "*")].select do |file|
      File.file?(file) && (file.include?("/cfn_nag/") || file.end_with?("LICENSE.cfn_nag"))
    end.map { |file| file.delete_prefix("#{FIXTURES}/") }.sort

    assert_equal pinned.sort, stored, "sha256.txt and the tree disagree"
  end

  def test_the_fixtures_say_what_the_templates_hold
    read = {}

    EXPECTED.each do |path, expected|
      violations = expected.select { |key, _| key.is_a?(String) }.transform_values { |ids| ids }
      skipped = expected.fetch(:skip, {})
      template = NagTemplate.load(File.join(FIXTURES, "cfn_nag", path))
      read[path] = template
      report = RubyCdk::Nag.check(template)

      found = report.violations.group_by(&:rule).transform_values { |found| found.map(&:logical_id) }
      assert_equal violations, found, "#{path}: the rules did not read the template as it was read by hand"
      assert_equal skipped, report.skipped.group_by(&:rule).transform_values(&:length), "#{path}: not decided where expected"
      assert_empty report.suppressed, path
      assert_empty report.warnings, path
    end
    assert_equal EXPECTED.length, read.length
  end

  def test_the_files_that_are_not_listed_are_clean
    Dir[File.join(FIXTURES, "cfn_nag", "**", "*")].select { |f| File.file?(f) }.sort.each do |file|
      path = file.delete_prefix("#{FIXTURES}/cfn_nag/")
      next if EXPECTED.key?(path)

      report = RubyCdk::Nag.check(NagTemplate.load(file))

      assert_empty report.violations, "#{path} was expected to be clean"
      assert_empty report.skipped, "#{path} was expected to be clean"
    end
  end

  # --- the scoreboard: fixtures that hit and do not hit, per rule

  def test_the_scoreboard
    scoreboard = RubyCdk::Nag.rules.to_h { |rule| [ rule.id, { hit: 0, miss: 0, undecided: 0, absent: 0 } ] }
    config = RubyCdk::Nag::Config.default

    fixtures = Dir[File.join(FIXTURES, "cfn_nag", "**", "*")].select { |f| File.file?(f) }.sort
    fixtures.each do |file|
      path = file.delete_prefix("#{FIXTURES}/cfn_nag/")
      template = NagTemplate.load(file)
      types = template.fetch("Resources", {}).values.select { |r| r.is_a?(Hash) }.map { |r| r["Type"] }
      report = RubyCdk::Nag.check(template, config: config)
      hit_rules = report.violations.map(&:rule).uniq
      undecided_rules = report.skipped.map(&:rule).uniq

      RubyCdk::Nag.rules.each do |rule|
        applies = rule.id == "RC-STATE-001" ? types.any? { |t| config.stateful_types.include?(t) } : types.any? { |t| rule.resource_types&.include?(t) }
        entry = scoreboard.fetch(rule.id)
        if hit_rules.include?(rule.id)
          entry[:hit] += 1
        elsif undecided_rules.include?(rule.id)
          entry[:undecided] += 1
        elsif applies
          entry[:miss] += 1
        else
          entry[:absent] += 1
        end
      end
    end

    puts
    puts "Security rules, over the #{fixtures.length} cfn-nag fixtures (docs/07-testing.md §11):"
    puts "  rule           hits  does-not-hit  undecided  not-applicable"
    scoreboard.each do |id, entry|
      puts format("  %-14s %4d %9d %10d %6d", id, entry[:hit], entry[:miss], entry[:undecided], entry[:absent])
    end

    # What the corpus cannot say, read from the templates, is pinned here so
    # that a change is a decision (test/fixtures/nag/README.md says why).
    assert_equal 0, scoreboard.dig("RC-STATE-001", :hit), "no fixture deletes a stateful resource"
    assert_equal 0, scoreboard.dig("RC-EC2-002", :hit), "no fixture opens a web port to the world"
    assert_equal 0, scoreboard.dig("RC-LAMBDA-001", :miss), "every fixture function runs on a retired runtime"
    assert_equal 0, scoreboard.dig("RC-LAMBDA-002", :hit), "no fixture declares an environment"

    # Every other rule hits and does not hit: both sides of each rule.
    (RubyCdk::Nag::Rules.ids - %w[RC-STATE-001 RC-EC2-002 RC-LAMBDA-001 RC-LAMBDA-002]).each do |id|
      assert_operator scoreboard.dig(id, :hit), :>=, 1, "#{id} has no fixture that hits it"
      assert_operator scoreboard.dig(id, :miss), :>=, 1, "#{id} has no fixture that does not hit it"
    end
  end
end
