# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/aws-sqs/test/sqs.test.ts, in aws/aws-cdk
#   Commit:  c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-25)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 59 cases. Each ported one keeps its name, as a comment above
# the test, and what it expects. What changed to get there:
#
#   - The origin's `new Stack()` is `stack` here, `Template.fromStack` is
#     `template`; `Template.fromStack(...).hasResource` is has_resource, and
#     the origin's testGrant is grant_statement below, granted to a Role
#     instead of a User (no User construct in this wave; the policy carries
#     Roles where the origin's carries Users).
#   - The logical ID is the ids above the resource joined, never hashed
#     (D-004, D-029): Queue4A7E3555 is QueueResource, MyQueueE6CA6235 is
#     MyQueueResource.
#
# Changed expectations, stated next to the test:
#
#   - "default properties": the CDK writes UpdateReplacePolicy Delete and
#     DeletionPolicy Delete on the queue; here the queue is deleted all the
#     same but nothing is written (architecture section 7: only the types the
#     CDK retains carry policies, and only under this tool's values). The
#     origin's hasResource DeletionPolicy Delete is therefore the one
#     expectation that cannot port.
#
# Not ported, with the reason:
#
#   Not ported because this tool does not have the feature:
#   - with a dead letter queue, and the dead-letter-source-queue permission
#     cases (default and explicit, the refusals). No deadLetterQueue prop in
#     this wave.
#   - the prop-validation cases (out-of-range retentionPeriod and deliveryDelay,
#     maxMessageSizeBytes and its token case). No such props here; the L1
#     resource: is the way to write one.
#   - addToPolicy will automatically create a policy for this queue, and the
#     queue-policy validation cases (fails if no actions / no IAM principals,
#     the redriveAllowPolicy cases). This tool grants to identities only; the
#     queue has no policy of its own here.
#   - the importing cases (fromQueueAttributes, fromQueueArn, fifo detection on
#     imports, cross-region env, grants on imported queues, grant on CfnQueue
#     with a KMS key or through the queue policy). Lookups are not in 0.1.0
#     (D-022), and this tool grants to constructs of this stack.
#   - the encryption cases (kms key allocated, managed key, sqs-managed,
#     unencrypted, encryptionType always KMS, grant also affects key). There is
#     no KMS Key construct in this wave.
#   - enforceSSL can be enabled. No enforceSSL prop here.
#   - the fifo cases beyond the suffix (fifo: false dropped, high-throughput
#     props, deduplicationScope and fifoThroughputLimit refusals). Only
#     fifo: is carried in this wave.
#   - test metrics, and the metric alarm case. No metrics here.
#
# Parity: 59 cases in the origin; 6 ported; 53 not ported.

require "test_helper"
require "support/cdk_constructs"

class CdkConstructsQueueTest < CdkConstructs::TestCase
  def test_default_properties
    # Changed: no UpdateReplacePolicy and DeletionPolicy are written here; the
    # queue is deleted all the same (see the header).
    built = stack do
      RubyCdk::SQS::Queue.new(self, "Queue")
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "QueueResource" => {
          "Type" => "AWS::SQS::Queue"
        }
      }
    ))
  end

  def test_message_retention_period_can_be_provided_as_a_parameter
    # Changed: this tool's parameter keeps the name the user wrote, and a
    # logical ID is letters and digits, so the name is the origin's resolved
    # one, myretentionperiod.
    built = stack do
      retention = parameter("myretentionperiod", type: "Number", default: 60)
      RubyCdk::SQS::Queue.new(self, "MyQueue", retention: Fn.ref(retention))
    end

    template(built).template_matches(with_format_version(
      "Parameters" => {
        "myretentionperiod" => {
          "Type" => "Number",
          "Default" => 60
        }
      },
      "Resources" => {
        "MyQueueResource" => {
          "Type" => "AWS::SQS::Queue",
          "Properties" => {
            "MessageRetentionPeriod" => { "Ref" => "myretentionperiod" }
          }
        }
      }
    ))
  end

  def test_grant_consume_messages
    built = stack do
      q = RubyCdk::SQS::Queue.new(self, "MyQueue")
      user = RubyCdk::IAM::Role.new(self, "User", assumed_by: "lambda.amazonaws.com")
      q.grant_consume_messages(user)
    end

    grant_statement(template(built), [
      "sqs:ReceiveMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueUrl",
      "sqs:DeleteMessage", "sqs:GetQueueAttributes"
    ])
  end

  def test_grant_send_messages
    built = stack do
      q = RubyCdk::SQS::Queue.new(self, "MyQueue")
      user = RubyCdk::IAM::Role.new(self, "User", assumed_by: "lambda.amazonaws.com")
      q.grant_send_messages(user)
    end

    grant_statement(template(built), [ "sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl" ])
  end

  def test_grant_purge
    built = stack do
      q = RubyCdk::SQS::Queue.new(self, "MyQueue")
      user = RubyCdk::IAM::Role.new(self, "User", assumed_by: "lambda.amazonaws.com")
      q.grant_purge(user)
    end

    grant_statement(template(built), [ "sqs:PurgeQueue", "sqs:GetQueueAttributes", "sqs:GetQueueUrl" ])
  end

  def test_grant_is_general_purpose
    built = stack do
      q = RubyCdk::SQS::Queue.new(self, "MyQueue")
      user = RubyCdk::IAM::Role.new(self, "User", assumed_by: "lambda.amazonaws.com")
      q.grant(user, "service:hello", "service:world")
    end

    grant_statement(template(built), [ "service:hello", "service:world" ])
  end

  private

  # The origin's testGrant: the statement the principal's policy carries, the
  # queue's ARN as its resource.
  def grant_statement(template, actions)
    template.has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ {
          "Action" => actions,
          "Effect" => "Allow",
          "Resource" => { "Fn::GetAtt" => [ "MyQueueResource", "Arn" ] }
        } ],
        "Version" => "2012-10-17"
      },
      "Roles" => [ { "Ref" => "UserResource" } ]
    })
  end
end
