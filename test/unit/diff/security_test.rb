# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/diff"

module DiffTests
  # The security view (architecture section 10): the statements a template
  # carries, found exact by resource type and by the property names AWS
  # publishes policy documents in, and the capabilities the new template asks
  # of CloudFormation that the deployed one did not. The CDK's broadening and
  # statement cases are ported beside these, in test/cdk/diff/.
  class SecurityTest < Minitest::Test
    def test_the_statements_of_an_added_role_policy_are_found
      diff = diff_with(role("Readers", policies: [ statement_policy("Read", "s3:ListBucket") ]))

      assert_equal 1, diff.security.statement_additions.length
      rendered = diff.security.statement_additions.first.render
      assert_equal "Allow", rendered[:effect]
      assert_equal "s3:ListBucket", rendered[:action]
      # An identity's inline policy applies to the identity: its principal is
      # the resource (the CDK's readIdentityPolicies).
      assert_equal "AWS:${Readers}", rendered[:principal]
    end

    def test_a_statement_that_was_already_deployed_reports_nothing
      policy = [ statement_policy("Read", "s3:ListBucket") ]
      diff = RubyCdk::Diff.of({ "Resources" => role("Readers", policies: policy) },
        { "Resources" => role("Readers", policies: policy) })

      refute_predicate diff.security, :has_changes?
    end

    def test_a_removed_statement_is_a_removal
      old = { "Resources" => role("Readers", policies: [ statement_policy("Read", "s3:ListBucket") ]) }
      new = { "Resources" => role("Readers", policies: []) }

      assert_equal 1, RubyCdk::Diff.of(old, new).security.statement_removals.length
    end

    def test_a_changed_statement_is_a_removal_and_an_addition
      old = { "Resources" => role("Readers", policies: [ statement_policy("Read", "s3:ListBucket") ]) }
      new = { "Resources" => role("Readers", policies: [ statement_policy("Read", "s3:GetObject") ]) }
      security = RubyCdk::Diff.of(old, new).security

      assert_equal 1, security.statement_additions.length
      assert_equal 1, security.statement_removals.length
      assert_predicate security, :broadening?
    end

    def test_the_trust_policy_of_a_role_is_read_wherever_it_sits
      trust = { "Statement" => { "Effect" => "Allow", "Principal" => { "Service" => "sns.amazonaws.com" }, "Action" => "sts:AssumeRole" } }
      old = { "Resources" => role("Assumed") }
      new = { "Resources" => role("Assumed", assume: trust) }

      assert_equal 1, RubyCdk::Diff.of(old, new).security.statement_additions.length
    end

    def test_a_resource_policy_applies_to_the_resource_it_is_attached_to
      queue_policy = { "Type" => "AWS::SQS::QueuePolicy", "Properties" => {
        "Queues" => [ { "Ref" => "TheQueue" } ],
        "PolicyDocument" => { "Statement" => { "Effect" => "Allow", "Action" => "sqs:SendMessage", "Resource" => "*",
          "Principal" => { "Service" => "sns.amazonaws.com" } } }
      } }
      diff = RubyCdk::Diff.of({ "Resources" => {} }, { "Resources" => { "Policy" => queue_policy } })

      rendered = diff.security.statement_additions.first.render
      # The statement's resource is the queue the policy attaches to (the
      # CDK's readResourcePolicyResource); where the statement already names
      # "*", the CDK replaces the star with it.
      assert_equal "${TheQueue}", rendered[:resource]
    end

    def test_an_iam_policy_resource_reads_one_statement_set_per_principal
      policy = { "Type" => "AWS::IAM::Policy", "Properties" => {
        "Roles" => [ { "Ref" => "TheRole" } ],
        "Users" => [ { "Ref" => "TheUser" } ],
        "PolicyDocument" => { "Statement" => { "Effect" => "Allow", "Action" => "s3:*", "Resource" => "*" } }
      } }
      diff = RubyCdk::Diff.of({ "Resources" => {} }, { "Resources" => { "Policy" => policy } })

      principals = diff.security.statement_additions.map { |statement| statement.render[:principal] }
      assert_equal %w[AWS:${TheRole} AWS:${TheUser}], principals.sort
    end

    def test_a_lambda_permission_reads_as_the_statement_lambda_writes
      permission = { "Type" => "AWS::Lambda::Permission", "Properties" => {
        "Action" => "lambda:InvokeFunction", "FunctionName" => { "Ref" => "Fn" },
        "Principal" => "111122223333", "SourceArn" => "arn:aws:sns:eu-west-1:111122223333:topic"
      } }
      diff = RubyCdk::Diff.of({ "Resources" => {} }, { "Resources" => { "Invoke" => permission } })

      rendered = diff.security.statement_additions.first.render
      assert_equal "Allow", rendered[:effect]
      assert_equal "${Fn}", rendered[:resource]
      # The account principal reads as the CDK renders an object principal:
      # "key:value" of the one entry.
      assert_equal "AWS:arn:aws:iam::111122223333:root", rendered[:principal]
      assert_includes rendered[:condition], "AWS:SourceArn"
    end

    def test_policies_are_found_inside_types_the_cdk_cannot_scrutinize
      # A KMS key policy: the CDK's service metadata may not say this property
      # carries statements; ours reads every property name AWS publishes one in.
      key = { "Type" => "AWS::KMS::Key", "Properties" => {
        "KeyPolicy" => { "Statement" => { "Effect" => "Allow", "Action" => "kms:*", "Resource" => "*", "Principal" => { "AWS" => "arn:aws:iam::111122223333:root" } } }
      } }
      diff = RubyCdk::Diff.of({ "Resources" => {} }, { "Resources" => { "Key" => key } })

      assert_equal 1, diff.security.statement_additions.length
    end

    def test_managed_policy_attachments_are_their_own_table
      old = { "Resources" => role("Operator") }
      new = { "Resources" => role("Operator", managed_policy_arns: [ "arn:aws:iam::aws:policy/ReadOnlyAccess" ]) }
      security = RubyCdk::Diff.of(old, new).security

      assert_equal 1, security.managed_policy_additions.length
      assert_equal "${Operator}", security.managed_policy_additions.first.identity
      assert_equal "arn:aws:iam::aws:policy/ReadOnlyAccess", security.managed_policy_additions.first.arn
      assert_predicate security, :broadening?
    end

    def test_a_deny_added_does_not_broaden_but_a_deny_taken_away_does
      deny = { "Effect" => "Deny", "Action" => "s3:*", "Resource" => "*", "Principal" => "*" }
      allow = { "Effect" => "Allow", "Action" => "s3:GetObject", "Resource" => "*", "Principal" => "*" }

      # A Deny that appears narrows what the deployed template may do, so it is
      # not a broadening; the CDK's isNegativeStatement says which side counts.
      refute_predicate security_after(allow, deny).security, :broadening?
      assert_predicate security_after(deny, allow).security, :broadening?
    end

    def test_a_capability_affects_a_change_only_when_the_type_or_its_policies_change
      plain = RubyCdk::Diff.of({ "Resources" => queue_with("QueueName" => "a") }, { "Resources" => queue_with("QueueName" => "b") })
      refute plain.security.security_change?(plain.changes.first)

      role_change = RubyCdk::Diff.of({ "Resources" => role("R") }, { "Resources" => {} })
      assert role_change.security.security_change?(role_change.changes.first)
    end

    def test_a_capability_the_new_template_needs_is_reported_once
      old = { "Resources" => queue_with("QueueName" => "a") }
      resources = queue_with("QueueName" => "b")
      resources.merge!(role("NewRole"))
      new = { "Resources" => resources }

      assert_equal %w[CAPABILITY_IAM], RubyCdk::Diff.of(old, new).security.capabilities_added
    end

    def test_an_explicitly_named_iam_resource_needs_the_named_capability
      old = { "Resources" => queue_with("QueueName" => "a") }
      named = role("Named")
      named["Named"]["Properties"] = { "RoleName" => "explicit-name" }
      new = { "Resources" => named }

      assert_equal %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM], RubyCdk::Diff.of(old, new).security.capabilities_added
    end

    def test_capabilities_already_deployed_are_not_reported_again
      template = { "Resources" => role("Steady") }

      assert_empty RubyCdk::Diff.of(template, template).security.capabilities_added
    end

    def test_the_machine_object_carries_the_view
      diff = diff_with(role("Readers", policies: [ statement_policy("Read", "s3:ListBucket") ]))
      object = diff.security.to_h

      assert_equal true, object["broadening"]
      assert_equal %w[CAPABILITY_IAM], object["capabilities_added"]
      assert_equal 1, object["statements"]["additions"].length
      assert_equal "s3:ListBucket", object["statements"]["additions"].first["actions"]["values"].first
      assert_equal({ "not" => false, "values" => [ "AWS:${Readers}" ] }, object["statements"]["additions"].first["principals"])
    end

    private

    def diff_with(resource)
      RubyCdk::Diff.of({ "Resources" => {} }, { "Resources" => resource })
    end

    # The security view after a role's one policy statement changed from the
    # first document to the second.
    def security_after(before, after)
      old_policy = { "PolicyName" => "p", "PolicyDocument" => { "Statement" => before } }
      new_policy = { "PolicyName" => "p", "PolicyDocument" => { "Statement" => after } }
      RubyCdk::Diff.of({ "Resources" => role("P", policies: [ old_policy ]) }, { "Resources" => role("P", policies: [ new_policy ]) })
    end

    def queue_with(properties)
      { "Queue" => { "Type" => "AWS::SQS::Queue", "Properties" => properties } }
    end

    def role(logical_id, policies: [], assume: nil, managed_policy_arns: nil)
      properties = { "AssumeRolePolicyDocument" => assume }.compact
      properties["Policies"] = policies unless policies.empty?
      properties["ManagedPolicyArns"] = managed_policy_arns if managed_policy_arns
      resource = { "Type" => "AWS::IAM::Role" }
      resource["Properties"] = properties unless properties.empty?
      { logical_id => resource }
    end

    def statement_policy(name, action)
      { "PolicyName" => name, "PolicyDocument" => { "Statement" => { "Effect" => "Allow", "Action" => action, "Resource" => "*" } } }
    end
  end
end
