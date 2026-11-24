# Fixtures for the security rules

Templates that `test/unit/nag/cfn_nag_fixtures_test.rb` runs the rule pack
(`lib/ruby_cdk/nag`) over. Every expectation is written by hand in that test,
with the reason next to it.

## Origin, commit, licence

- **Origin:** `stelligent/cfn_nag` on GitHub, directory `spec/test_templates`.
- **Commit:** `8b5f03da74202ba323a145e9d037ddce6cab9dec` (its HEAD on 2026-11-23).
- **Licence:** MIT. The text is in `LICENSE.cfn_nag`, which is the repository's
  `LICENSE.md` at that commit, unmodified (Copyright (c) 2016-2021 Stelligent).
- **Nothing was changed.** Each file under `cfn_nag/` keeps the path it has
  under `spec/test_templates/` and its bytes: several end without a final
  newline and one has two trailing spaces, on purpose. `sha256.txt` holds the
  SHA-256 of every file, and the test fails if one byte of one of them changes.

## How they were chosen

The repository holds 714 templates under `spec/test_templates` (212 JSON, 502
YAML). They were listed with the GitHub tree API, read through the contents API
(and, to search all of them at once, from the tarball of the commit above),
and a template was kept when reading it showed one of three things for a rule
of the pack:

1. the rule hits: a resource of the rule's type has the weakness;
2. the rule is checked and does not hit: a resource of the rule's type is
   written the safe way, or in a way that looks unsafe and is not (a `Deny`, a
   named principal, a condition);
3. the rule cannot decide: a value it needs is a `Ref` or an intrinsic, or has
   a shape it cannot read.

Left out, and why:

- templates whose resources no rule of the pack reads;
- `json/kms/*.json` and four `json/lambda_function/*.json`, whose indentation
  holds tab characters: their YAML twins are kept instead, since a tab is
  easily lost when a file is written out by hand;
- `json/security_group/ip6_security_groups_open_to_world.json`, the twin of the
  YAML file that is kept;
- `yaml/iam_passrole_resource_wildcard/iam_role_passrole_resource_wildcard_fail.yml`
  and `iam_inline_policy_passrole_resource_wildcard_fail.yml`, whose `Type`
  value ends with a space (`AWS::IAM::Role `): which rule applies to such a
  resource is not something an expectation should rest on.

## What the corpus does not have

Read from the templates, not assumed. Each of these is covered by a template
written in the unit test, and said so there.

- **`RC-STATE-001` hits nothing.** No template sets `DeletionPolicy` on a
  stateful resource; the only two that set one at all retain a Secrets Manager
  secret.
- **`RC-LAMBDA-002` has nothing.** No function declares an `Environment`.
- **`RC-LAMBDA-001` has no passing template.** Every function runs on
  `nodejs6.10`, except one on `nodejs`: none on a runtime Lambda supports today.
- **`RC-IAM-003` hits only through an inline policy.** No template declares an
  `AWS::IAM::AccessKey`.
- **`RC-EC2-002` hits nothing here.** Exactly one template in the corpus has an
  ingress open to the world on port 80 or 443: `e2e/ElastiCache.template`, a
  17.6 KB sample with CRLF line endings whose line 222 is
  `{"IpProtocol" : "tcp", "FromPort" : "80", "ToPort" : "80", "CidrIp" : "0.0.0.0/0", "Description": "Inbound HTTP" }`.
  It is not kept, because bytes with CRLF cannot be written out by hand
  faithfully; the unit test writes its two ingress rules instead.

## How the tests read them

- JSON with `JSON.parse`.
- YAML with Psych, through `test/support/nag_template.rb`. Psych on its own
  drops the short forms (`!Ref X` loads as the string `"X"`, which a rule would
  read as a literal), so the reader writes them in long form as cfn-model 0.6.6
  does for cfn-nag (`!Ref` → `{"Ref" => ...}`, `!Sub` → `{"Fn::Sub" => ...}`,
  and so on), and keeps `::/0` a string.

Where this tool reads a template differently from cfn-nag, the expectations
follow this tool, and say so in the test:

- cfn-model gives every condition the value `true` and resolves `Fn::If`
  through its first branch; here `Fn::If` is a dynamic value, and the check
  that meets it is counted as not decided.
- cfn-nag follows a `Ref` into `Parameters`; here a `Ref` is dynamic.
- cfn-nag's own suppression metadata (`cfn_nag:` / `rules_to_suppress:`) is not
  this tool's (`RubyCdk::Nag` / `RulesToSuppress`), so it suppresses nothing
  here: `yaml/security_group/sg_with_suppression.yml` pins that.
- cfn-nag's W59 lets every `OPTIONS` method through; this tool ports cdk-nag's
  `APIGWAuthorization`, which lets one through only when its responses are the
  CORS preflight's.

## The files, and what each one shows

"Hits" names the rule and the logical IDs it is reported on. "Not decided"
names the rule and how many of its checks could not be decided. A dash means
nothing was found and nothing was left undecided.

| File under `cfn_nag/` | Hits | Not decided |
|---|---|---|
| `json/security_group/security_group_open_to_world_on_ingress.json` | RC-EC2-001: `sgOpenIngress` (one inline rule, written as an object), `securityGroupIngress` (standalone) | |
| `json/security_group/standalone_ingress_open_to_world.json` | RC-EC2-001: `securityGroupIngress` | |
| `json/security_group/single_security_group_empty_ingress.json` | | |
| `json/security_group/single_security_group_one_cidr_ingress.json` | | |
| `json/security_group/non_32_cidr_standalone_ingress.json` | | RC-EC2-001 and RC-EC2-002, 3 each: `securityGroupIngress2`, `4`, `5` |
| `yaml/security_group/ip6_security_groups_open_to_world.yml` | RC-EC2-001: `InstanceSecurityGroup`, `InstanceSecurityGroup2`, `InstanceSecurityGroup3`, `securityGroupIngress` | |
| `yaml/security_group/security_group_rule_description_pass.yml` | | |
| `yaml/security_group/bad_cidr_in_parameter.yml` | | RC-EC2-001 and RC-EC2-002, 1 each: `InstanceSecurityGroup` |
| `yaml/security_group/pesky_if.yml` | | |
| `yaml/security_group/sg_with_suppression.yml` | RC-EC2-001: `securityGroupIngress`, `securityGroupIngress2` | |
| `json/s3_bucket_policy/s3_bucket_with_wildcards.json` | RC-S3-001: `S3Bucket`, `S3Bucket2`, `S3Bucket3`. RC-POLICY-001: `S3BucketPolicy2` | |
| `json/s3_bucket_policy/s3_bucket_policy_with_not_action.json` | RC-S3-001: `S3Bucket` | |
| `json/sqs_queue_policy/sqs_queue_with_wildcards.json` | RC-POLICY-001: `mysqspolicy2`, `mysqspolicy2b`, `mysqspolicy2c` | |
| `json/sqs_queue_policy/sqs_policy_with_not_action.json` | | |
| `json/sns_topic_policy/sns_topic_with_wildcard_principal.json` | RC-POLICY-001: `mysnspolicy0`, `mysnspolicy1`, `mysnspolicy2`, `mysnspolicy3` | |
| `json/sns_topic_policy/sns_topic_with_not_action.json` | | |
| `yaml/kms/kms_key_with_wildcard_principal.yml` | RC-POLICY-001: `myKeyWildcardPrincipal` | |
| `yaml/kms/kms_key_without_wildcard_principal.yml` | | |
| `json/s3_bucket/buckets_with_access_logging.json` | RC-S3-001: `S3BucketNoAccessLogging` | |
| `yaml/s3/bucket_with_no_policy.yml` | RC-S3-001: `Bucket`, `Bucket2` | |
| `yaml/s3/bucket_with_non_literal_policy.yml` | RC-S3-001: `S3Bucket` | RC-POLICY-001, 1: `S3BucketPolicy` |
| `yaml/gamelift/support_resources.yml` | RC-IAM-002: `IamRole` | |
| `json/iam_policy/iam_policy_with_wildcard_action.json` | | RC-IAM-001 and RC-IAM-002, 1 each: `WildcardActionPolicy` |
| `json/iam_policy/iam_policy_with_wildcard_resource.json` | | |
| `json/iam_managed_policy/iam_managed_policy_with_wildcard_action.json` | RC-IAM-002: `CreateTestDBPolicy3` | |
| `json/iam_role/iam_role.json` | RC-IAM-001 and RC-IAM-002: `RootRole` | |
| `json/iam_role/iam_role_with_wildcard_action.json` | RC-IAM-002: `WildcardActionRole` | |
| `json/iam_role/iam_role_with_wildcard_action_on_trust.json` | | |
| `yaml/iam_role/embedded_sub.yml` | | RC-IAM-001 and RC-IAM-002, 1 each: `HelperRole` |
| `yaml/iam_passrole_resource_wildcard/iam_role_passrole_resource_wildcard_pass.yml` | | |
| `json/iam_user/iam_user_with_inline_policy.json` | RC-IAM-003: `userWithInline` | |
| `json/iam_user/iam_user_with_one_group.json` | | |
| `json/lambda_function/lambda_with_lambda_execute_managed_policy.json` | RC-LAMBDA-001: `FunctionWithLambdaExecuteManagedPolicyRoleByRef`, `FunctionWithLambdaExecuteManagedPolicyRoleByFnGetAtt` | |
| `yaml/lambda_function/lambda_with_managed_policies.yaml` | RC-LAMBDA-001: `FunctionWithLogsManagedPolicyRoleByRef`, `FunctionWithLogsManagedPolicyRoleByGetAtt`, `FunctionWithLogsManagedPolicyRoleByFnGetAtt`, `FunctionWithOtherManagedPolicyRoleByRef` | |
| `yaml/dynamodb/dynamodb_table_with_backup_enabled.yaml` | | |
| `yaml/dynamodb/dynamodb_table_with_no_backup_enabled.yaml` | RC-DYNAMODB-001: `DynamodbNoBackupEnabled`, `DynamodbNoBackupEnabled2` | |
| `json/ec2_volume/ebs_volume_with_encryption.json` | | |
| `json/ec2_volume/ebs_volume_with_kms_key.json` | | |
| `json/ec2_volume/ebs_volume_without_encryption_string.json` | RC-EBS-001: `NewVolumeA` | |
| `json/ec2_volume/ebs_volume_without_encryption_string_externalized.json` | | RC-EBS-001, 1: `NewVolumeA` |
| `json/ec2_volume/two_ebs_volumes_with_no_encryption.json` | RC-EBS-001: `NewVolume1`, `NewVolume2` | |
| `json/rds_instance/db_instance_with_encryption.json` | | |
| `json/rds_instance/db_instance_with_no_encryption.json` | RC-RDS-001: `MyDB` | |
| `json/rds_instance/db_instance_with_encryption_false.json` | RC-RDS-001: `MyDB` | |
| `json/rds_instance/db_instance_with_clusterid_and_encryption_false.json` | | |
| `json/rds_instance/db_cluster_with_encryption.json` | | |
| `json/rds_instance/db_cluster_with_no_encryption.json` | RC-RDS-001: `RDSCluster` | |
| `yaml/api_gateway/api_gateway_method_authorization_type_none.yaml` | RC-APIGW-001: `ApiGatewayMethod1`, `ApiGatewayMethod2`, `ApiGatewayMethod3` | |
| `yaml/api_gateway/api_gateway_method_authorization_type_nil_value.yaml` | RC-APIGW-001: `ApiGatewayMethod1`, `ApiGatewayMethod2` | |
| `yaml/api_gateway/api_gateway_method_authorization_type_none_with_param_refs.yaml` | | RC-APIGW-001, 3: `ApiGatewayMethod1`, `2`, `3` |
| `yaml/api_gateway/api_gateway_method_authorization_type_valid_values.yaml` | | |
| `yaml/api_gateway/api_gateway_method_with_httpmethod_options.yaml` | RC-APIGW-001: `ApiGatewayMethod1`, `ApiGatewayMethod2`, `ApiGatewayMethod5`, `ApiGatewayMethod6` | RC-APIGW-001, 4: `ApiGatewayMethod3`, `4` (`AuthorizationType`), `5`, `6` (`HttpMethod`) |
| `yaml/cloudwatchlogs_loggroup/cloudwatchlogs_loggroup_with_retention.yaml` | | |
| `yaml/cloudwatchlogs_loggroup/cloudwatchlogs_loggroup_without_retention.yaml` | RC-LOGS-001: `CWLogGroup` | |

`RC-STATE-001` reads every stateful resource of these templates (the buckets,
the tables, the volumes, the RDS instances and clusters, the log group) and
finds none deleted: its passing side. Its failing side is written in the unit
test.
