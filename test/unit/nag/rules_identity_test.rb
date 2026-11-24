# frozen_string_literal: true

require "test_helper"
require "support/nag_case"

# The rules over principals: RC-POLICY-001, RC-IAM-001, RC-IAM-002, RC-IAM-003.
class NagRulesIdentityTest < Minitest::Test
  include NagCase

  BUCKET_POLICY = "AWS::S3::BucketPolicy"
  QUEUE_POLICY = "AWS::SQS::QueuePolicy"
  TOPIC_POLICY = "AWS::SNS::TopicPolicy"
  KEY = "AWS::KMS::Key"
  POLICY = "AWS::IAM::Policy"
  MANAGED_POLICY = "AWS::IAM::ManagedPolicy"
  ROLE = "AWS::IAM::Role"
  USER = "AWS::IAM::User"
  GROUP = "AWS::IAM::Group"
  ACCESS_KEY = "AWS::IAM::AccessKey"
  NO_VALUE = { "Ref" => "AWS::NoValue" }.freeze

  def policy_document(statements)
    { "PolicyName" => "p", "PolicyDocument" => { "Version" => "2012-10-17", "Statement" => statements } }
  end

  # One statement, written as the template writes it: String keys.
  def statement(**fields)
    fields.transform_keys(&:to_s)
  end

  # --- RC-POLICY-001: a wildcard principal in a resource policy

  def test_resource_policy_passes_when_the_principal_is_named
    named = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Statement" => [
      statement(Effect: "Allow", Principal: { "AWS" => "arn:aws:iam::123456789012:root" }, Action: "s3:GetObject", Resource: "arn:aws:s3:::b/*")
    ] } })
    service = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Statement" => [
      statement(Effect: "Allow", Principal: { "Service" => [ "gamelift.amazonaws.com" ] }, Action: "s3:GetObject", Resource: "arn:aws:s3:::b/*")
    ] } })

    assert_findings(named, {})
    assert_findings(service, {})
  end

  def test_resource_policy_passes_when_the_statement_denies_or_restricts
    deny = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Statement" => [
      statement(Effect: "Deny", Principal: "*", Action: "s3:PutObject", Resource: "arn:aws:s3:::b/*")
    ] } })
    restricted = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Statement" => [
      statement(Effect: "Allow", Principal: "*", Action: "s3:GetObject", Resource: "arn:aws:s3:::b/*",
        Condition: { "IpAddress" => { "aws:SourceIp" => "10.0.0.0/8" } })
    ] } })
    empty_condition_still_grants = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Statement" => [
      statement(Effect: "Allow", Principal: "*", Action: "s3:GetObject", Resource: "arn:aws:s3:::b/*", Condition: {})
    ] } })

    assert_findings(deny, {})
    assert_findings(restricted, {})
    assert_one_violation(empty_condition_still_grants, "RC-POLICY-001", severity: :high, resource_type: BUCKET_POLICY,
      path: "Properties.PolicyDocument.Statement[0].Principal", says: [ "wildcard principal", "Condition" ])
  end

  def test_resource_policy_fails_on_a_wildcard_principal_written_every_way_cloudformation_writes_it
    bare = check_resource(KEY, { "KeyPolicy" => { "Statement" => [ statement(Effect: "Allow", Principal: "*", Action: "kms:*", Resource: "*") ] } })
    in_aws = check_resource(QUEUE_POLICY, { "PolicyDocument" => { "Statement" => [ statement(Effect: "Allow", Principal: { "AWS" => "*" }, Action: "sqs:SendMessage", Resource: "*") ] } })
    in_an_array = check_resource(KEY, { "KeyPolicy" => { "Statement" => [ statement(Effect: "Allow", Principal: { "AWS" => [ "arn:aws:iam::1:root", "*" ] }, Action: "kms:*", Resource: "*") ] } })
    among_others = check_resource(TOPIC_POLICY, { "PolicyDocument" => { "Statement" => [ statement(Effect: "Allow", Principal: { "AWS" => "*", "CanonicalUser" => "x" }, Action: "sns:Publish", Resource: "*") ] } })
    one_statement_only = check_resource(KEY, { "KeyPolicy" => { "Statement" => [
      statement(Effect: "Allow", Principal: { "AWS" => "arn:aws:iam::1:root" }, Action: "kms:*", Resource: "*"),
      statement(Sid: "public", Effect: "Allow", Principal: "*", Action: "kms:Encrypt", Resource: "*")
    ] } })

    assert_one_violation(bare, "RC-POLICY-001", severity: :high, resource_type: KEY, path: "Properties.KeyPolicy.Statement[0].Principal", says: [ "wildcard principal" ])
    assert_one_violation(in_aws, "RC-POLICY-001", severity: :high, resource_type: QUEUE_POLICY, path: "Properties.PolicyDocument.Statement[0].Principal", says: [ "wildcard principal" ])
    assert_one_violation(in_an_array, "RC-POLICY-001", severity: :high, resource_type: KEY, path: "Properties.KeyPolicy.Statement[0].Principal", says: [ "wildcard principal" ])
    assert_one_violation(among_others, "RC-POLICY-001", severity: :high, resource_type: TOPIC_POLICY, path: "Properties.PolicyDocument.Statement[0].Principal", says: [ "wildcard principal" ])
    assert_one_violation(one_statement_only, "RC-POLICY-001", severity: :high, resource_type: KEY, path: "Properties.KeyPolicy.Statement[1].Principal", says: [ "wildcard principal" ])
  end

  def test_resource_policy_finds_the_statement_written_as_one_object
    report = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Statement" => statement(Effect: "Allow", Principal: "*", Action: "s3:GetObject", Resource: "*") } })

    assert_one_violation(report, "RC-POLICY-001", severity: :high, resource_type: BUCKET_POLICY, path: "Properties.PolicyDocument.Statement.Principal", says: [ "wildcard principal" ])
  end

  def test_resource_policy_reads_a_policy_document_written_as_json_text
    document = JSON.generate({ "Statement" => [ { "Effect" => "Allow", "Principal" => "*", "Action" => "s3:GetObject", "Resource" => "*" } ] })
    report = check_resource(BUCKET_POLICY, { "PolicyDocument" => document })

    assert_one_violation(report, "RC-POLICY-001", severity: :high, resource_type: BUCKET_POLICY, path: "Properties.PolicyDocument.Statement[0].Principal", says: [ "wildcard principal" ])
  end

  def test_resource_policy_counts_a_dynamic_principal_or_document
    dynamic_principal = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Statement" => [
      statement(Effect: "Allow", Principal: { "AWS" => { "Ref" => "CallerArn" } }, Action: "s3:GetObject", Resource: "*")
    ] } })
    dynamic_document = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Ref" => "Policy" } })
    json_that_is_not = check_resource(BUCKET_POLICY, { "PolicyDocument" => "{not json" })

    skipped = assert_undecided(dynamic_principal, "RC-POLICY-001", path: "Properties.PolicyDocument.Statement[0].Principal")
    assert_includes skipped.reason, "dynamic"
    assert_undecided(dynamic_document, "RC-POLICY-001", path: "Properties.PolicyDocument")
    assert_undecided(json_that_is_not, "RC-POLICY-001", path: "Properties.PolicyDocument")
  end

  def test_resource_policy_reads_a_condition_structurally
    # A condition restricts whatever its values are: the rule does not read them.
    dynamic_values = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Statement" => [
      statement(Effect: "Allow", Principal: "*", Action: "s3:GetObject", Resource: "*", Condition: { "IpAddress" => { "aws:SourceIp" => { "Ref" => "Range" } } })
    ] } })
    dynamic_condition = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Statement" => [
      statement(Effect: "Allow", Principal: "*", Action: "s3:GetObject", Resource: "*",
        Condition: { "Fn::If" => [ "Restrict", { "IpAddress" => { "aws:SourceIp" => "10.0.0.0/8" } }, NO_VALUE ] })
    ] } })

    assert_findings(dynamic_values, {})
    assert_undecided(dynamic_condition, "RC-POLICY-001", path: "Properties.PolicyDocument.Statement[0].Condition")
  end

  def test_resource_policy_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(BUCKET_POLICY, { "PolicyDocument" => { "Statement" => [ statement(Effect: "Allow", Principal: "*", Action: "s3:GetObject", Resource: "*") ] } },
      **rules_to_suppress({ "Id" => "RC-POLICY-001", "Reason" => "A public download bucket; the objects are public anyway." }))

    assert_suppressed(report, "RC-POLICY-001", reason: "A public download bucket; the objects are public anyway.")
  end

  # --- RC-IAM-001: Action "*" with Resource "*"

  def test_iam_admin_access_fails_on_the_star_statement_written_with_lists_or_one_string
    lists = check_resource(POLICY, policy_document([ statement(Effect: "Allow", Action: "*", Resource: "*") ]))
    strings = check_resource(POLICY, policy_document([ { "Resource" => "*", "Effect" => "Allow", "Action" => "*" } ]))
    arn_wildcard = check_resource(POLICY, policy_document([ statement(Effect: "Allow", Action: "*", Resource: "arn:aws:s3:::b/*") ]))
    inline_on_a_role = check_resource(ROLE, { "Policies" => [ policy_document([ statement(Effect: "Allow", Action: "*", Resource: "*") ]) ] })

    assert_one_violation(lists, "RC-IAM-001", severity: :high, resource_type: POLICY, path: "Properties.PolicyDocument.Statement[0].Resource",
      says: [ "admin access", "name the actions and the resources" ])
    assert_one_violation(strings, "RC-IAM-001", severity: :high, resource_type: POLICY, path: "Properties.PolicyDocument.Statement[0].Resource", says: [ "admin access" ])
    assert_one_violation(arn_wildcard, "RC-IAM-001", severity: :high, resource_type: POLICY, path: "Properties.PolicyDocument.Statement[0].Resource", says: [ "admin access" ])
    assert_one_violation(inline_on_a_role, "RC-IAM-001", severity: :high, resource_type: ROLE, path: "Properties.Policies[0].PolicyDocument.Statement[0].Resource", says: [ "admin access" ])
  end

  def test_iam_admin_access_passes_when_the_statement_is_not_a_grant_on_everything
    # NotResource is not Resource: the statement grants everything but one thing.
    # A service wildcard ("s3:*") clears RC-IAM-001, and is RC-IAM-002's finding.
    not_resource = check_resource(ROLE, { "Policies" => [ policy_document([ statement(Effect: "Allow", Action: "*", NotResource: "*") ]) ] })
    no_star_action = check_resource(POLICY, policy_document([ statement(Effect: "Allow", Action: "s3:GetObject", Resource: "*") ]))
    deny = check_resource(POLICY, policy_document([ statement(Effect: "Deny", Action: "*", Resource: "*") ]))
    trust_policy = check_resource(ROLE, { "AssumeRolePolicyDocument" => { "Statement" => [ statement(Effect: "Allow", Principal: { "Service" => "ec2.amazonaws.com" }, Action: "*") ] } })

    assert_findings(not_resource, { "RC-IAM-002" => [ "Only" ] })
    assert_findings(no_star_action, {})
    assert_findings(deny, {})
    assert_findings(trust_policy, {})
  end

  def test_iam_admin_access_is_suppressed_when_the_resource_says_so_with_a_reason
    # The star statement hits both IAM rules, so both ids are suppressed.
    report = check_resource(ROLE, { "Policies" => [ policy_document([ statement(Effect: "Allow", Action: "*", Resource: "*") ]) ] },
      **rules_to_suppress(
        { "Id" => "RC-IAM-001", "Reason" => "A deployment role; the wildcard is reviewed in the pull request." },
        { "Id" => "RC-IAM-002", "Reason" => "A deployment role; the wildcard is reviewed in the pull request." }
      ))

    assert_suppressed(report, "RC-IAM-001", reason: "A deployment role; the wildcard is reviewed in the pull request.")
    assert_suppressed(report, "RC-IAM-002", reason: "A deployment role; the wildcard is reviewed in the pull request.")
  end

  # --- RC-IAM-002: an Action that is "*"

  def test_iam_full_access_fails_on_a_star_or_service_wildcard_action
    star = check_resource(MANAGED_POLICY, policy_document([ statement(Effect: "Allow", Action: "*", Resource: "arn:aws:s3:::b") ]))
    service = check_resource(POLICY, policy_document([ statement(Effect: "Allow", Action: "s3:*", Resource: "arn:aws:s3:::b") ]))
    in_a_list = check_resource(POLICY, policy_document([ statement(Effect: "Allow", Action: [ "s3:GetObject", "s3:*" ], Resource: "arn:aws:s3:::b") ]))
    on_a_user = check_resource(USER, { "Policies" => [ policy_document([ statement(Effect: "Allow", Action: "s3:*", Resource: "*") ]) ] })
    on_a_group = check_resource(GROUP, { "Policies" => [ policy_document([ statement(Effect: "Allow", Action: "*", Resource: "*") ]) ] })

    assert_one_violation(star, "RC-IAM-002", severity: :medium, resource_type: MANAGED_POLICY, path: "Properties.PolicyDocument.Statement[0].Action",
      says: [ "full access", "name the actions" ])
    assert_one_violation(service, "RC-IAM-002", severity: :medium, resource_type: POLICY, path: "Properties.PolicyDocument.Statement[0].Action", says: [ "full access" ])
    assert_one_violation(in_a_list, "RC-IAM-002", severity: :medium, resource_type: POLICY, path: "Properties.PolicyDocument.Statement[0].Action", says: [ "full access" ])
    assert_one_violation(on_a_user, "RC-IAM-002", severity: :medium, resource_type: USER, path: "Properties.Policies[0].PolicyDocument.Statement[0].Action", says: [ "full access" ])
    assert_one_violation(on_a_group, "RC-IAM-002", severity: :medium, resource_type: GROUP, path: "Properties.Policies[0].PolicyDocument.Statement[0].Action", says: [ "full access" ])
  end

  def test_iam_full_access_passes_on_scoped_actions_and_on_a_deny
    scoped = check_resource(POLICY, policy_document([ statement(Effect: "Allow", Action: [ "s3:Get*", "s3:List*" ], Resource: "*") ]))
    deny = check_resource(POLICY, policy_document([ statement(Effect: "Deny", Action: "*", Resource: "*") ]))
    not_action = check_resource(POLICY, policy_document([ statement(Effect: "Allow", NotAction: "s3:*", Resource: "*") ]))

    assert_findings(scoped, {})
    assert_findings(deny, {})
    assert_findings(not_action, {})
  end

  def test_iam_full_access_counts_an_action_it_cannot_read_and_leaves_the_rest
    dynamic_action = check_resource(POLICY, policy_document([
      statement(Effect: "Allow", Action: { "Fn::If" => [ "Wide", "*", "s3:GetObject" ] }, Resource: "arn:aws:s3:::b"),
      statement(Effect: "Allow", Action: [ "s3:GetObject", { "Fn::Join" => [ "", [ "dynamodb:", "*" ] ] } ], Resource: "*")
    ]))

    assert_empty violations(dynamic_action, "RC-IAM-002")
    assert_equal 2, undecided(dynamic_action, "RC-IAM-002").length
  end

  def test_iam_full_access_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(POLICY, policy_document([ statement(Effect: "Allow", Action: "s3:*", Resource: "arn:aws:s3:::b") ]),
      **rules_to_suppress({ "Id" => "RC-IAM-002", "Reason" => "The replication job needs every s3 action on this one bucket." }))

    assert_suppressed(report, "RC-IAM-002", reason: "The replication job needs every s3 action on this one bucket.")
  end

  # --- RC-IAM-003: an access key or an inline policy on a user

  def test_iam_user_credentials_passes_on_a_user_with_neither
    plain = check_resource(USER, { "Groups" => [ "developers" ] })
    bare = check_resource(USER, {})

    assert_findings(plain, {})
    assert_findings(bare, {})
  end

  def test_iam_user_credentials_fails_on_an_inline_policy_and_on_an_access_key
    inline = check_resource(USER, { "Policies" => [ policy_document([ statement(Effect: "Allow", Action: "s3:GetObject", Resource: "*") ]) ] })
    two_policies = check_resource(USER, { "Policies" => [ policy_document([ statement(Effect: "Allow", Action: "a:B", Resource: "*") ]), policy_document([ statement(Effect: "Allow", Action: "c:D", Resource: "*") ]) ] })
    empty_policies = check_resource(USER, { "Policies" => [] })
    key = check_resource(ACCESS_KEY, { "UserName" => "deploy", "Status" => "Active" })
    key_by_ref = check_resource(ACCESS_KEY, { "UserName" => { "Ref" => "User" } })

    assert_one_violation(inline, "RC-IAM-003", severity: :medium, resource_type: USER, path: "Properties.Policies",
      says: [ "1 inline policy", "managed policies" ])
    assert_one_violation(two_policies, "RC-IAM-003", severity: :medium, resource_type: USER, path: "Properties.Policies", says: [ "2 inline policies" ])
    assert_findings(empty_policies, {})
    assert_one_violation(key, "RC-IAM-003", severity: :medium, resource_type: ACCESS_KEY, path: "Properties.UserName",
      says: [ "access key", "long-lived credential", "deploy", "role instead" ])
    assert_one_violation(key_by_ref, "RC-IAM-003", severity: :medium, resource_type: ACCESS_KEY, path: "Properties.UserName", says: [ "access key" ])
  end

  def test_iam_user_credentials_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(ACCESS_KEY, { "UserName" => "deploy" }, **rules_to_suppress({ "Id" => "RC-IAM-003", "Reason" => "A break-glass key in a vault, rotated monthly." }))

    assert_suppressed(report, "RC-IAM-003", reason: "A break-glass key in a vault, rotated monthly.")
  end

  def test_iam_user_credentials_counts_a_dynamic_policy_list
    report = check_resource(USER, { "Policies" => { "Ref" => "Policies" } })

    assert_undecided(report, "RC-IAM-003", path: "Properties.Policies")
  end

  # --- one policy, both rules

  def test_one_statement_can_hit_both_iam_rules_and_be_suppressed_by_each_id
    both = check_resource(POLICY, policy_document([ statement(Effect: "Allow", Action: "*", Resource: "*") ]))

    assert_one_violation(both, "RC-IAM-001", severity: :high, resource_type: POLICY, path: "Properties.PolicyDocument.Statement[0].Resource", says: [ "admin access" ])
    assert_one_violation(both, "RC-IAM-002", severity: :medium, resource_type: POLICY, path: "Properties.PolicyDocument.Statement[0].Action", says: [ "full access" ])

    # One suppression per id: acknowledging one rule leaves the other in place.
    half = check_resource(POLICY, policy_document([ statement(Effect: "Allow", Action: "*", Resource: "*") ]), **rules_to_suppress({ "Id" => "RC-IAM-001", "Reason" => "The admin statement is the subject of the incident review." }))

    assert_empty violations(half, "RC-IAM-001")
    assert_one_violation(half, "RC-IAM-002", severity: :medium, resource_type: POLICY, path: "Properties.PolicyDocument.Statement[0].Action", says: [ "full access" ])
  end
end
