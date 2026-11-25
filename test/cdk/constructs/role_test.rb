# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/aws-iam/test/role.test.ts, in aws/aws-cdk
#   Commit:  c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-25)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 57 cases. Each ported one keeps its name, as a comment above
# the test, and what it expects. What changed to get there:
#
#   - The origin's `new Stack()` is `stack` here (CdkConstructs::TestCase#stack);
#     `Template.fromStack` is `template`. Every whole-template expectation adds
#     AWSTemplateFormatVersion, which the serialization contract writes here
#     always (with_format_version).
#   - `new iam.Role(stack, 'MyRole', { assumedBy: new iam.ServicePrincipal('sns.amazonaws.com') })`
#     is RubyCdk::IAM::Role.new(stack, "MyRole", assumed_by: "sns.amazonaws.com"):
#     a principal is named by what it is - a service name, an ARN, an account
#     id, "*", a Hash, or a list of them - not by a principal class.
#   - The logical ID is the ids above the resource joined, never hashed
#     (D-004, D-029): MyRoleF48FFE04 is MyRole here.
#   - grantAssumeRole and grantPassRole are granted to another Role, not to a
#     User: this wave ships no User construct, and a Role is the IGrantable
#     every construct's grant targets here. The statement is the origin's; the
#     policy carries Roles where the origin's carries Users.
#   - maxSessionDuration takes seconds, not a Duration.
#
# Changed expectations, stated next to the test:
#
#   - PolicyName of the DefaultPolicy is the whole logical ID
#     (MyRoleDefaultPolicy); the origin's carries an 8-character hash behind it
#     (generatePolicyName, aws-iam/lib/private/util.ts, takes the last 128
#     characters of a hashed logical ID). Our logical IDs are never hashed.
#
# Not ported, with the reason:
#
#   Not ported because this tool does not have the feature:
#   - Role.isRole (true/false/undefined), customizeRoles and precreated roles
#     (throws if precreatedRoles is not used; a token; preventSynthesis=false;
#     works at the app scope, a relative scope and an absolute scope; can use
#     all role properties; does not create policies). There are no precreated
#     roles and no context system here; lookups of existing resources are not
#     in 0.1.0 (D-022).
#   - externalIds, single and multiple. The trust policy carries them as a
#     Condition in the CDK; our Role takes assumed_by as a principal, a Hash or
#     a list, and a Hash can carry the condition verbatim. The explicit
#     externalId props join when a wave asks for them.
#   - federated principal can change AssumeRoleAction. There is no
#     FederatedPrincipal here.
#   - role path: used, one character, empty, over 512, must start and end with
#     a forward slash, unicode characters. No path prop in this wave.
#   - permissions boundary managed policy, and the qualifier and stage cases of
#     the permissions-boundary block. No PermissionsBoundary prop yet; it is a
#     row for a later wave, not a silent omission.
#   - fails if managed policy is invalid / default role policy is invalid /
#     inline policy from props is invalid / attached inline policy is invalid /
#     assumeRolePolicy is invalid. These test the CDK's policy-document
#     validation (V-rules) inside aws-iam; this tool validates templates at
#     synthesis, from AWS's own schemas (architecture section 6), which the
#     validation suite covers.
#   - can be applied to an app / to a stage / to a stage with placeholders, and
#     the cross-env role ARNs include path case. There is no Stage and no
#     cross-env reference here (D-003).
#   - too many managed policies warning, and Dependables track the final
#     declaring construct. There are no Annotations and no dependable objects
#     here; a resource's DependsOn is declared when it is created.
#   - many copies of the same statement do not result in overflow policies
#     (splitLargePolicy). A statement that outgrows IAM's 10,240-character
#     policy quota is not split here; the refusal comes from CloudFormation at
#     deploy, and the splitting is backlog.
#   - roleName validation with Tokens. There are no tokens to validate: a
#     physical name is a literal or nothing.
#
# Parity: 57 cases in the origin; 16 ported; 41 not ported.

require "test_helper"
require "support/cdk_constructs"

class CdkConstructsRoleTest < CdkConstructs::TestCase
  def test_default_role
    built = stack do
      RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: "sns.amazonaws.com")
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyRoleResource" => {
          "Type" => "AWS::IAM::Role",
          "Properties" => {
            "AssumeRolePolicyDocument" => {
              "Statement" => [ {
                "Action" => "sts:AssumeRole",
                "Effect" => "Allow",
                "Principal" => { "Service" => "sns.amazonaws.com" }
              } ],
              "Version" => "2012-10-17"
            }
          }
        }
      }
    ))
  end

  def test_allow_role_with_multiple_principals
    built = stack do
      RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: [ "boom.amazonaws.test", "111111111111" ])
    end

    template(built).has_resource_properties("AWS::IAM::Role", {
      "AssumeRolePolicyDocument" => {
        "Statement" => [
          { "Action" => "sts:AssumeRole", "Effect" => "Allow", "Principal" => { "Service" => "boom.amazonaws.test" } },
          { "Action" => "sts:AssumeRole", "Effect" => "Allow", "Principal" => { "AWS" => "111111111111" } }
        ],
        "Version" => "2012-10-17"
      }
    })
  end

  def test_policy_is_created_automatically_when_permissions_are_added
    # by default we don't expect a role policy
    before = stack do
      RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: "sns.amazonaws.com")
    end
    template(before).resource_count_is("AWS::IAM::Policy", 0)

    # add a policy to the role
    after = stack do
      role = RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: "sns.amazonaws.com")
      role.add_to_policy(RubyCdk::IAM::PolicyStatement.new(resources: [ "arn:aws:s3:::BucketName" ], actions: [ "service:myaction" ]))
    end
    # Changed: PolicyName is the whole logical ID, MyRoleDefaultPolicy; the
    # origin's carries an 8-character hash behind it.
    template(after).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ { "Action" => "service:myaction", "Effect" => "Allow", "Resource" => "arn:aws:s3:::BucketName" } ],
        "Version" => "2012-10-17"
      },
      "PolicyName" => "MyRoleDefaultPolicy",
      "Roles" => [ { "Ref" => "MyRoleResource" } ]
    })
  end

  def test_managed_policy_arns_can_be_supplied_upon_initialization_and_also_added_later
    built = stack do
      role = RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: "test.service",
        managed_policy_arns: [ "managed1", "managed2" ])
      role.add_managed_policy("managed3")
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyRoleResource" => {
          "Type" => "AWS::IAM::Role",
          "Properties" => {
            "AssumeRolePolicyDocument" => {
              "Statement" => [ {
                "Action" => "sts:AssumeRole",
                "Effect" => "Allow",
                "Principal" => { "Service" => "test.service" }
              } ],
              "Version" => "2012-10-17"
            },
            "ManagedPolicyArns" => [ "managed1", "managed2", "managed3" ]
          }
        }
      }
    ))
  end

  def test_managed_policy_arns_are_deduplicated
    built = stack do
      role = RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: "sns.amazonaws.com",
        managed_policy_arns: [ "arn:aws:iam::aws:policy/SuperDeveloper", "arn:aws:iam::aws:policy/SuperDeveloper" ])
      role.add_to_policy(RubyCdk::IAM::PolicyStatement.new(actions: [ "s3:*" ], resources: [ "*" ]))
      20.times { role.add_managed_policy("arn:aws:iam::aws:policy/SuperDeveloper") }
    end

    template(built).has_resource_properties("AWS::IAM::Role", {
      "ManagedPolicyArns" => [ "arn:aws:iam::aws:policy/SuperDeveloper" ]
    })
  end

  def test_principal_star_in_an_assume_role_policy_document_gets_translated_to_aws_star
    # The docs say that "Principal: *" and "Principal: { AWS: * }" are equivalent,
    # but in practice CreateRole errors out if you use "Principal: *" in an
    # AssumeRolePolicyDocument. Make sure that we handle this case specially.
    built = stack do
      RubyCdk::IAM::Role.new(self, "Role", assumed_by: "*")
    end

    template(built).has_resource_properties("AWS::IAM::Role", {
      "AssumeRolePolicyDocument" => {
        "Statement" => [ {
          "Action" => "sts:AssumeRole",
          "Effect" => "Allow",
          "Principal" => { "AWS" => "*" }
        } ],
        "Version" => "2012-10-17"
      }
    })
  end

  def test_max_session_duration_is_not_specified_by_default
    built = stack do
      RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: "sns.amazonaws.com")
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyRoleResource" => {
          "Type" => "AWS::IAM::Role",
          "Properties" => {
            "AssumeRolePolicyDocument" => {
              "Statement" => [ {
                "Action" => "sts:AssumeRole",
                "Effect" => "Allow",
                "Principal" => { "Service" => "sns.amazonaws.com" }
              } ],
              "Version" => "2012-10-17"
            }
          }
        }
      }
    ))
  end

  def test_max_session_duration_can_be_used_to_specify_the_maximum_session_duration_for_assuming_the_role
    built = stack do
      RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: "sns.amazonaws.com", max_session_duration: 3700)
    end

    template(built).has_resource_properties("AWS::IAM::Role", {
      "MaxSessionDuration" => 3700
    })
  end

  def test_max_session_duration_must_be_between_3600_and_43200
    # Changed: the message names this tool's keyword, max_session_duration,
    # and the seconds are given directly, not as a Duration.
    build_stack do
      RubyCdk::IAM::Role.new(self, "MyRole1", assumed_by: "bla", max_session_duration: 3600)
      RubyCdk::IAM::Role.new(self, "MyRole2", assumed_by: "bla", max_session_duration: 43_200)
    end

    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::IAM::Role.new(self, "MyRole3", assumed_by: "bla", max_session_duration: 60) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::IAM::Role.new(self, "MyRole4", assumed_by: "bla", max_session_duration: 3599) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::IAM::Role.new(self, "MyRole5", assumed_by: "bla", max_session_duration: 43_201) }
    end
  end

  def test_can_have_a_description
    built = stack do
      RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: "sns.amazonaws.com", description: "This is a role description.")
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyRoleResource" => {
          "Type" => "AWS::IAM::Role",
          "Properties" => {
            "AssumeRolePolicyDocument" => {
              "Statement" => [ {
                "Action" => "sts:AssumeRole",
                "Effect" => "Allow",
                "Principal" => { "Service" => "sns.amazonaws.com" }
              } ],
              "Version" => "2012-10-17"
            },
            "Description" => "This is a role description."
          }
        }
      }
    ))
  end

  def test_should_not_have_an_empty_description
    built = stack do
      RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: "sns.amazonaws.com", description: "")
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyRoleResource" => {
          "Type" => "AWS::IAM::Role",
          "Properties" => {
            "AssumeRolePolicyDocument" => {
              "Statement" => [ {
                "Action" => "sts:AssumeRole",
                "Effect" => "Allow",
                "Principal" => { "Service" => "sns.amazonaws.com" }
              } ],
              "Version" => "2012-10-17"
            }
          }
        }
      }
    ))
  end

  def test_description_can_only_be_1000_characters_long
    # Changed: the message names the bound in this tool's words; the origin's
    # says "Role description must be no longer than 1000 characters."
    assert_raises(RubyCdk::UsageError) do
      build_stack do
        RubyCdk::IAM::Role.new(self, "MyRole", assumed_by: "sns.amazonaws.com", description: "d" * 1001)
      end
    end
  end

  def test_doesnt_throw_with_role_name_of_64_chars
    built = stack do
      RubyCdk::IAM::Role.new(self, "Test", assumed_by: "sns.amazonaws.com", role_name: "a" * 64)
    end

    template(built).has_resource_properties("AWS::IAM::Role", { "RoleName" => "a" * 64 })
  end

  def test_throws_with_role_name_over_64_chars
    assert_raises(RubyCdk::UsageError) do
      build_stack do
        RubyCdk::IAM::Role.new(self, "Test", assumed_by: "sns.amazonaws.com", role_name: "a" * 65)
      end
    end
  end

  def test_a_role_can_grant_pass_role_permissions
    # Changed: granted to another Role, not to a User; the policy carries Roles
    # where the origin's carries Users.
    built = stack do
      role = RubyCdk::IAM::Role.new(self, "Role", assumed_by: "henk.amazonaws.com")
      other = RubyCdk::IAM::Role.new(self, "User", assumed_by: "ecs-tasks.amazonaws.com")
      role.grant_pass_role(other)
    end

    template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ {
          "Action" => "iam:PassRole",
          "Effect" => "Allow",
          "Resource" => { "Fn::GetAtt" => [ "RoleResource", "Arn" ] }
        } ],
        "Version" => "2012-10-17"
      },
      "Roles" => [ { "Ref" => "UserResource" } ]
    })
  end

  def test_a_role_can_grant_assume_role_permissions
    # Changed: granted to another Role, not to a User (see the header).
    built = stack do
      role = RubyCdk::IAM::Role.new(self, "Role", assumed_by: "henk.amazonaws.com")
      other = RubyCdk::IAM::Role.new(self, "User", assumed_by: "ecs-tasks.amazonaws.com")
      role.grant_assume_role(other)
    end

    template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ {
          "Action" => "sts:AssumeRole",
          "Effect" => "Allow",
          "Resource" => { "Fn::GetAtt" => [ "RoleResource", "Arn" ] }
        } ],
        "Version" => "2012-10-17"
      },
      "Roles" => [ { "Ref" => "UserResource" } ]
    })
  end

  private

  # One stack whose build is the block, so that a refused construct leaves the
  # raise to the caller's assert_raises.
  def build_stack(&body)
    RubyCdk::Stack.new(build_app, "Stack", &body)
    nil
  end
end
