# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/aws-logs/test/loggroup.test.ts, in aws/aws-cdk
#   Commit:  c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-25)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 53 cases. Each ported one keeps its name, as a comment above
# the test, and what it expects. What changed to get there:
#
#   - The origin's `new Stack()` is `stack` here, `Template.fromStack` is
#     `template`; retention takes days as an Integer here and RetentionDays
#     there (ONE_WEEK is 7, TWO_YEARS is 731, INFINITE is :infinite).
#   - The logical ID is the ids above the resource joined, never hashed
#     (D-004, D-029): LogGroupF5B46931 is LogGroupResource here.
#
# Changed expectations, stated next to the test:
#
#   - "infinite retention/dont delete log group by default": the group is a
#     retained type here with RetainExceptOnCreate as the deletion policy and
#     Retain as the replace policy, where the CDK writes Retain on both
#     (architecture section 7 wins; the row is in section 21).
#   - "grant read": the bare group ARN is written as an Fn::Sub over
#     CloudFormation's own pseudo parameters (this tool carries no partition,
#     region and account references to join), then the GetAtt Arn, so the two
#     resources of the origin's statement are here too.
#
# Not ported, with the reason:
#
#   Not ported because this tool does not have the feature:
#   - set kms key when provided, and allows an encryption key (KMS is supported
#     for DELIVERY). There is no KMS Key construct in this wave.
#   - the logGroupClass cases (INFREQUENT_ACCESS, STANDARD, DELIVERY, the
#     default-class retention behaviour). No logGroupClass prop here.
#   - unresolved retention (a token as retention). There are no tokens here.
#   - will delete log group if asked to. No removalPolicy prop on this
#     construct this wave; the L1 resource's deletion_policy: is the way to
#     write one, and section 7 keeps the group retained.
#   - import from ARN (same region, different region) and import from name.
#     Lookups of existing resources are not in 0.1.0 (D-022).
#   - extractMetric, and the metric-filter, subscription, destination,
#     data-protection and field-index cases. No such props in this wave.
#   - grants.read on an imported or L1 log group, grantRead on a token ARN, and
#     grants.actions with given resource ARNs. Grants here go to constructs of
#     this stack; the generic actions grant arrives with a wave that needs it.
#
# Parity: 53 cases in the origin; 5 ported; 48 not ported.

require "test_helper"
require "support/cdk_constructs"

class CdkConstructsLogGroupTest < CdkConstructs::TestCase
  def test_fixed_retention
    built = stack do
      RubyCdk::Logs::LogGroup.new(self, "LogGroup", retention_days: 7)
    end

    template(built).has_resource_properties("AWS::Logs::LogGroup", {
      "RetentionInDays" => 7
    })
  end

  def test_default_retention
    built = stack do
      RubyCdk::Logs::LogGroup.new(self, "LogGroup")
    end

    template(built).has_resource_properties("AWS::Logs::LogGroup", {
      "RetentionInDays" => 731
    })
  end

  def test_infinite_retention_dont_delete_log_group_by_default
    # Changed: RetainExceptOnCreate as the deletion policy and Retain as the
    # replace policy, this tool's retention for the types the CDK retains
    # (see the header).
    built = stack do
      RubyCdk::Logs::LogGroup.new(self, "LogGroup", retention_days: :infinite)
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "LogGroupResource" => {
          "Type" => "AWS::Logs::LogGroup",
          "DeletionPolicy" => "RetainExceptOnCreate",
          "UpdateReplacePolicy" => "Retain"
        }
      }
    ))
  end

  def test_grant_write
    # Changed: granted to a Role, not to a User (no User construct in this
    # wave); the policy carries Roles.
    built = stack do
      group = RubyCdk::Logs::LogGroup.new(self, "LogGroup")
      user = RubyCdk::IAM::Role.new(self, "User", assumed_by: "lambda.amazonaws.com")
      group.grant_write(user)
    end

    template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ {
          "Action" => [ "logs:CreateLogStream", "logs:PutLogEvents" ],
          "Effect" => "Allow",
          "Resource" => { "Fn::GetAtt" => [ "LogGroupResource", "Arn" ] }
        } ],
        "Version" => "2012-10-17"
      },
      "Roles" => [ { "Ref" => "UserResource" } ]
    })
  end

  def test_grant_read
    # Changed: granted to a Role, not to a User; the bare group ARN is an
    # Fn::Sub over the pseudo parameters (see the header).
    built = stack do
      group = RubyCdk::Logs::LogGroup.new(self, "LogGroup")
      user = RubyCdk::IAM::Role.new(self, "User", assumed_by: "lambda.amazonaws.com")
      group.grant_read(user)
    end

    template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ {
          "Action" => [ "logs:FilterLogEvents", "logs:GetLogEvents", "logs:GetLogGroupFields",
            "logs:DescribeLogGroups", "logs:DescribeLogStreams" ],
          "Effect" => "Allow",
          "Resource" => [
            {
              "Fn::Sub" => [
                "arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:${Group}",
                { "Group" => { "Ref" => "LogGroupResource" } }
              ]
            },
            { "Fn::GetAtt" => [ "LogGroupResource", "Arn" ] }
          ]
        } ],
        "Version" => "2012-10-17"
      },
      "Roles" => [ { "Ref" => "UserResource" } ]
    })
  end
end
