# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/aws-sns/test/sns.test.ts, in aws/aws-cdk
#   Commit:  c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-25)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 54 cases. Each ported one keeps its name, as a comment above
# the test, and what it expects. What changed to get there:
#
#   - The origin's `new cdk.Stack()` is `stack` here, `Template.fromStack` is
#     `template`.
#   - The logical ID is the ids above the resource joined, never hashed
#     (D-004, D-029): TopicBFC7AF6E is TopicResource, MyTopicB4B3F8BB is
#     MyTopicResource.
#
# Changed expectations, stated next to the test:
#
#   - "give publishing permissions": granted to a Role instead of a User (no
#     User construct in this wave); the policy carries Roles where the origin's
#     carries Users, and the topic's ARN is the GetAtt of TopicResource.
#
# Not ported, with the reason:
#
#   Not ported because this tool does not have the feature:
#   - topic without logging configs omits DeliveryStatusLogging, and specify
#     kmsMasterKey. No logging configs and no KMS key construct in this wave.
#   - Adds .fifo suffix when no topicName is passed. With no topic_name this
#     tool writes no TopicName, and CloudFormation names the topic at creation;
#     there is no generated physical name to suffix.
#   - specify signatureVersion, throw with incorrect signatureVersion, throw
#     error when displayName is too long. No signatureVersion prop here; the
#     display name goes to the service as it is.
#   - can add a policy to the topic, can enforce ssl (two), the
#     TopicPolicy-passed-document and Add-statements cases, Create topic policy
#     and enforce ssl, topic resource policy includes unique SIDs. This tool
#     grants to identities only; the topic has no policy of its own here, and
#     the enforce-SSL statement arrives with the policy machinery.
#   - give publishing permissions to CfnTopic, give arbitrary set of
#     permissions to CfnTopic, give service principal permissions to publish to
#     CfnTopic (two). Grants on an L1 resource are not a case here: grants go
#     to the principal's policy through a construct.
#   - give publishing permissions with masterKey, refer to masterKey. No KMS
#     key construct in this wave.
#   - give subscribing permissions to CfnTopic, and the subscription cases of
#     subscription.test.ts. Only grant_publish and grant_subscribe are carried
#     in this wave, and the subscribe case is not among the defaults.
#
# Parity: 54 cases in the origin; 10 ported; 44 not ported.

require "test_helper"
require "support/cdk_constructs"

class CdkConstructsTopicTest < CdkConstructs::TestCase
  def test_all_defaults
    built = stack do
      RubyCdk::SNS::Topic.new(self, "MyTopic")
    end

    template(built).resource_count_is("AWS::SNS::Topic", 1)
  end

  def test_specify_topic_name
    built = stack do
      RubyCdk::SNS::Topic.new(self, "MyTopic", topic_name: "topicName")
    end

    template(built).has_resource_properties("AWS::SNS::Topic", {
      "TopicName" => "topicName"
    })
  end

  def test_specify_display_name
    built = stack do
      RubyCdk::SNS::Topic.new(self, "MyTopic", display_name: "displayName")
    end

    template(built).has_resource_properties("AWS::SNS::Topic", {
      "DisplayName" => "displayName"
    })
  end

  def test_specify_display_name_and_topic_name
    built = stack do
      RubyCdk::SNS::Topic.new(self, "MyTopic", display_name: "displayName", topic_name: "topicName")
    end

    template(built).has_resource_properties("AWS::SNS::Topic", {
      "TopicName" => "topicName",
      "DisplayName" => "displayName"
    })
  end

  def test_specify_fifo_without_fifo_suffix_in_topic_name
    built = stack do
      RubyCdk::SNS::Topic.new(self, "MyTopic", fifo: true, topic_name: "topicName")
    end

    template(built).has_resource_properties("AWS::SNS::Topic", {
      "FifoTopic" => true,
      "TopicName" => "topicName.fifo"
    })
  end

  def test_specify_fifo_with_fifo_suffix_in_topic_name
    built = stack do
      RubyCdk::SNS::Topic.new(self, "MyTopic", fifo: true, topic_name: "topicName.fifo")
    end

    template(built).has_resource_properties("AWS::SNS::Topic", {
      "FifoTopic" => true,
      "TopicName" => "topicName.fifo"
    })
  end

  def test_specify_fifo_without_content_based_deduplication
    built = stack do
      RubyCdk::SNS::Topic.new(self, "MyTopic", fifo: true, topic_name: "topicName")
    end

    template(built).has_resource_properties("AWS::SNS::Topic", {
      "FifoTopic" => true,
      "TopicName" => "topicName.fifo"
    })
  end

  def test_specify_fifo_with_content_based_deduplication
    built = stack do
      RubyCdk::SNS::Topic.new(self, "MyTopic",
        content_based_deduplication: true, fifo: true, topic_name: "topicName")
    end

    template(built).has_resource_properties("AWS::SNS::Topic", {
      "ContentBasedDeduplication" => true,
      "FifoTopic" => true,
      "TopicName" => "topicName.fifo"
    })
  end

  def test_throw_with_content_based_deduplication_on_non_fifo_topic
    assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::SNS::Topic.new(self, "MyTopic", content_based_deduplication: true)
      end
    end
  end

  def test_give_publishing_permissions
    # Changed: granted to a Role instead of a User (see the header).
    built = stack do
      topic = RubyCdk::SNS::Topic.new(self, "Topic")
      user = RubyCdk::IAM::Role.new(self, "User", assumed_by: "lambda.amazonaws.com")
      topic.grant_publish(user)
    end

    template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Version" => "2012-10-17",
        "Statement" => [ {
          "Action" => "sns:Publish",
          "Effect" => "Allow",
          # SNS's ARN attribute is TopicArn, not Arn.
          "Resource" => { "Fn::GetAtt" => [ "TopicResource", "TopicArn" ] }
        } ]
      },
      "Roles" => [ { "Ref" => "UserResource" } ]
    })
  end
end
