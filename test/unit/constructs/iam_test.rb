# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/constructs"
require "ruby_cdk/test"
require "support/core_helpers"

# This tool's own tests of the constructs layer's shared pieces: the
# PolicyStatement, the Grant, and the IAM::Role behaviour the CDK's test file
# does not reach here (docs/07-testing.md section 10: what no CDK test covers).
class ConstructsIamTest < CoreHelpers::TestCase
  Fn = RubyCdk::Fn

  # --- PolicyStatement

  def test_a_statement_renders_in_the_cdk_s_key_order
    statement = RubyCdk::IAM::PolicyStatement.new(
      actions: [ "s3:GetObject*", "s3:GetBucket*" ],
      resources: [ "arn:aws:s3:::b", "arn:aws:s3:::b/*" ],
      principals: "lambda.amazonaws.com",
      conditions: { Bool: { "aws:SecureTransport" => "false" } },
      sid: "DenyInsecure"
    )

    assert_equal(
      {
        "Action" => [ "s3:GetObject*", "s3:GetBucket*" ],
        "Condition" => { "Bool" => { "aws:SecureTransport" => "false" } },
        "Effect" => "Allow",
        "Principal" => { "Service" => "lambda.amazonaws.com" },
        "Resource" => [ "arn:aws:s3:::b", "arn:aws:s3:::b/*" ],
        "Sid" => "DenyInsecure"
      },
      statement.to_statement
    )
  end

  def test_one_action_and_one_resource_are_written_as_the_single_string
    statement = RubyCdk::IAM::PolicyStatement.new(
      actions: [ "lambda:InvokeFunction" ],
      resources: [ "arn:aws:lambda:eu-west-1:111122223333:function:f" ]
    )

    assert_equal "lambda:InvokeFunction", statement.to_statement["Action"]
    assert_equal "arn:aws:lambda:eu-west-1:111122223333:function:f", statement.to_statement["Resource"]
  end

  def test_a_statement_without_actions_or_resources_carries_only_its_keys
    statement = RubyCdk::IAM::PolicyStatement.new(effect: :deny, principals: "*")

    assert_equal({ "Effect" => "Deny", "Principal" => "*" }, statement.to_statement)
  end

  def test_principals_render_as_the_cdk_s_principals_do
    assert_equal "*", RubyCdk::IAM::PolicyStatement.principal_fragment("*")
    assert_equal({ "Service" => "sns.amazonaws.com" }, RubyCdk::IAM::PolicyStatement.principal_fragment("sns.amazonaws.com"))
    assert_equal({ "AWS" => "arn:aws:iam::111122223333:role/x" }, RubyCdk::IAM::PolicyStatement.principal_fragment("arn:aws:iam::111122223333:role/x"))
    assert_equal({ "AWS" => "111122223333" }, RubyCdk::IAM::PolicyStatement.principal_fragment("111122223333"))
    assert_equal({ "AWS" => "*" }, RubyCdk::IAM::PolicyStatement.principal_fragment({ AWS: "*" }))
  end

  def test_one_principal_hash_is_one_principal_not_a_list_of_pairs
    statement = RubyCdk::IAM::PolicyStatement.new(principals: { "AWS" => "*" })

    assert_equal({ "AWS" => "*" }, statement.to_statement["Principal"])
  end

  def test_several_principals_merge_under_their_key
    statement = RubyCdk::IAM::PolicyStatement.new(principals: [ "arn:aws:iam::111122223333:user/a", "arn:aws:iam::111122223333:user/b" ])

    assert_equal({ "AWS" => [ "arn:aws:iam::111122223333:user/a", "arn:aws:iam::111122223333:user/b" ] }, statement.to_statement["Principal"])
  end

  def test_an_unknown_effect_is_refused
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::IAM::PolicyStatement.new(effect: :loud) }

    assert_match(/effect must be :allow or :deny/, error.message)
  end

  # --- Grant

  def test_a_grant_carries_the_three_facts_a_statement_needs
    grant = RubyCdk::Constructs::Grant.add_to_principal("arn:aws:iam::111122223333:user/alice", [ "s3:ListBucket" ], [ "arn:aws:s3:::b" ])

    assert_equal "arn:aws:iam::111122223333:user/alice", grant.principal_arn
    assert_equal [ "s3:ListBucket" ], grant.actions
    assert_equal [ "arn:aws:s3:::b" ], grant.resource_arns
    refute grant.applied?, "an ARN principal cannot carry a statement, so the grant is returned unapplied"
    assert_equal({ "Action" => "s3:ListBucket", "Effect" => "Allow", "Resource" => "arn:aws:s3:::b" }, grant.to_statement)
  end

  def test_a_grant_to_a_role_is_applied_to_the_role_s_own_policy
    stack, role = build_stack do
      RubyCdk::IAM::Role.new(self, "Reader", assumed_by: "lambda.amazonaws.com")
    end

    grant = RubyCdk::Constructs::Grant.add_to_principal(role, [ "s3:ListBucket" ], [ "arn:aws:s3:::b" ])

    assert grant.applied?
    RubyCdk::Test.template(stack).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ { "Action" => "s3:ListBucket", "Effect" => "Allow", "Resource" => "arn:aws:s3:::b" } ],
        "Version" => "2012-10-17"
      },
      "Roles" => [ { "Ref" => "ReaderResource" } ]
    })
  end

  def test_a_grant_refuses_a_principal_it_cannot_name
    error = assert_raises(RubyCdk::UsageError) do
      RubyCdk::Constructs::Grant.add_to_principal(42, [ "s3:ListBucket" ], [ "arn:aws:s3:::b" ])
    end

    assert_match(/takes an IAM::Role or a principal ARN String/, error.message)
  end

  # --- Role: what no CDK case reaches here

  def test_a_role_used_twice_carries_two_distinct_resources_and_policies
    app = build_app(env: TEST_ENV)
    stack = RubyCdk::Stack.new(app, "stack") do
      first = RubyCdk::IAM::Role.new(self, "Role", assumed_by: "lambda.amazonaws.com")
      second = RubyCdk::IAM::Role.new(self, "Role2", assumed_by: "sns.amazonaws.com")
      first.add_to_policy(RubyCdk::IAM::PolicyStatement.new(actions: [ "s3:ListBucket" ], resources: [ "*" ]))
      second.add_to_policy(RubyCdk::IAM::PolicyStatement.new(actions: [ "dynamodb:Scan" ], resources: [ "*" ]))
    end
    template = RubyCdk::Test.template(stack)

    template.resource_count_is("AWS::IAM::Role", 2)
    template.resource_count_is("AWS::IAM::Policy", 2)
    template.has_resource_properties("AWS::IAM::Policy", { "PolicyName" => "RoleDefaultPolicy", "Roles" => [ { "Ref" => "RoleResource" } ] })
    template.has_resource_properties("AWS::IAM::Policy", { "PolicyName" => "Role2DefaultPolicy", "Roles" => [ { "Ref" => "Role2Resource" } ] })
  end

  def test_a_hash_statement_is_taken_verbatim
    built, = build_stack do
      role = RubyCdk::IAM::Role.new(self, "Role", assumed_by: "lambda.amazonaws.com")
      role.add_to_policy("Sid" => "Raw", "Effect" => "Deny", "Action" => "s3:*", "Resource" => "*")
    end

    RubyCdk::Test.template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ { "Sid" => "Raw", "Effect" => "Deny", "Action" => "s3:*", "Resource" => "*" } ],
        "Version" => "2012-10-17"
      }
    })
  end

  def test_to_inline_policy_writes_named_policies_into_the_role_s_policies_list
    built, = build_stack do
      role = RubyCdk::IAM::Role.new(self, "Role", assumed_by: "lambda.amazonaws.com")
      role.to_inline_policy([ RubyCdk::IAM::PolicyStatement.new(actions: [ "s3:ListBucket" ], resources: [ "*" ]) ], name: "reader")
    end

    RubyCdk::Test.template(built).has_resource_properties("AWS::IAM::Role", {
      "Policies" => [ {
        "PolicyName" => "reader",
        "PolicyDocument" => {
          "Version" => "2012-10-17",
          "Statement" => [ { "Action" => "s3:ListBucket", "Effect" => "Allow", "Resource" => "*" } ]
        }
      } ]
    })
  end

  def test_the_same_inline_policy_name_is_refused
    error = assert_raises(RubyCdk::UsageError) do
      build_stack do
        role = RubyCdk::IAM::Role.new(self, "Role", assumed_by: "lambda.amazonaws.com")
        statement = RubyCdk::IAM::PolicyStatement.new(actions: [ "s3:ListBucket" ], resources: [ "*" ])
        role.to_inline_policy([ statement ], name: "reader")
        role.to_inline_policy([ statement ], name: "reader")
      end
    end

    assert_match(/already an inline policy named "reader"/, error.message)
  end

  def test_an_empty_inline_policy_is_refused
    error = assert_raises(RubyCdk::UsageError) do
      build_stack do
        RubyCdk::IAM::Role.new(self, "Role", assumed_by: "lambda.amazonaws.com").to_inline_policy([], name: "empty")
      end
    end

    assert_match(/takes at least one statement/, error.message)
  end

  def test_grant_assume_role_refuses_a_service_principal
    error = assert_raises(RubyCdk::UsageError) do
      build_stack do
        RubyCdk::IAM::Role.new(self, "Role", assumed_by: "lambda.amazonaws.com").grant_assume_role("sns.amazonaws.com")
      end
    end

    assert_match(/use the assume_role_policy instead/, error.message)
  end

  def test_grant_pass_role_lands_on_the_other_role_s_policy
    built, = build_stack do
      passer = RubyCdk::IAM::Role.new(self, "Passer", assumed_by: "lambda.amazonaws.com")
      passed = RubyCdk::IAM::Role.new(self, "Passed", assumed_by: "ecs-tasks.amazonaws.com")
      passer.grant_pass_role(passed)
    end

    RubyCdk::Test.template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ { "Action" => "iam:PassRole", "Effect" => "Allow", "Resource" => { "Fn::GetAtt" => [ "PasserResource", "Arn" ] } } ],
        "Version" => "2012-10-17"
      },
      "Roles" => [ { "Ref" => "PassedResource" } ]
    })
  end

  def test_managed_policy_arns_added_after_the_role_was_built_are_written
    built, = build_stack do
      role = RubyCdk::IAM::Role.new(self, "Role", assumed_by: "lambda.amazonaws.com", managed_policy_arns: [ "managed1" ])
      role.add_managed_policy("managed2")
      role.add_managed_policy("managed1")
    end

    RubyCdk::Test.template(built).has_resource_properties("AWS::IAM::Role", { "ManagedPolicyArns" => [ "managed1", "managed2" ] })
  end

  private

  # One stack in an App with the test env, whose build is the block. Answers
  # [stack, the block's value], so a test keeps what it built and the template
  # the stack synthecizes into.
  def build_stack(&body)
    app = build_app(env: TEST_ENV)
    value = nil
    built = RubyCdk::Stack.new(app, "Stack") do
      value = instance_eval(&body)
    end
    [ built, value ]
  end
end
