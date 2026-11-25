# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/constructs"
require "ruby_cdk/test"
require "support/core_helpers"

# This tool's own tests of the SQS queue and the SNS topic, what no CDK case
# reaches here (docs/07-testing.md section 10): twice in one stack, the
# unnamed resources, a fifo queue's suffix, and the grants to an ARN principal.
class ConstructsQueueTopicTest < CoreHelpers::TestCase
  def test_a_queue_used_twice_carries_two_distinct_resources
    app = build_app(env: TEST_ENV)
    stack = RubyCdk::Stack.new(app, "stack") do
      RubyCdk::SQS::Queue.new(self, "Queue", queue_name: "one")
      RubyCdk::SQS::Queue.new(self, "Queue2", queue_name: "two")
    end
    template = RubyCdk::Test.template(stack)

    template.resource_count_is("AWS::SQS::Queue", 2)
    template.has_resource_properties("AWS::SQS::Queue", { "QueueName" => "one" })
    template.has_resource_properties("AWS::SQS::Queue", { "QueueName" => "two" })
  end

  def test_a_fifo_queue_carries_the_suffix_and_the_flag
    built, = build_stack do
      RubyCdk::SQS::Queue.new(self, "Queue", queue_name: "jobs", fifo: true)
    end

    template(built).has_resource_properties("AWS::SQS::Queue", {
      "QueueName" => "jobs.fifo",
      "FifoQueue" => true
    })
  end

  def test_a_queue_without_fifo_drops_the_flag
    built, = build_stack do
      RubyCdk::SQS::Queue.new(self, "Queue", queue_name: "plain", fifo: false)
    end

    template(built).has_resource_properties("AWS::SQS::Queue", {
      "FifoQueue" => RubyCdk::Test.absent()
    })
  end

  def test_a_queue_without_a_name_refers_to_its_resource
    _, queue = build_stack do
      RubyCdk::SQS::Queue.new(self, "Queue")
    end

    assert_equal({ "Ref" => "QueueResource" }, queue.queue_url)
    assert_equal({ "Fn::GetAtt" => [ "QueueResource", "Arn" ] }, queue.arn)
  end

  def test_a_topic_used_twice_carries_two_distinct_resources
    app = build_app(env: TEST_ENV)
    stack = RubyCdk::Stack.new(app, "stack") do
      RubyCdk::SNS::Topic.new(self, "Topic", topic_name: "one")
      RubyCdk::SNS::Topic.new(self, "Topic2", topic_name: "two")
    end
    template = RubyCdk::Test.template(stack)

    template.resource_count_is("AWS::SNS::Topic", 2)
    template.has_resource_properties("AWS::SNS::Topic", { "TopicName" => "one" })
    template.has_resource_properties("AWS::SNS::Topic", { "TopicName" => "two" })
  end

  def test_a_grant_to_an_arn_principal_is_returned_unapplied
    stack, queue = build_stack do
      RubyCdk::SQS::Queue.new(self, "Queue")
    end

    grant = queue.grant_send_messages("arn:aws:iam::111122223333:user/alice")

    refute grant.applied?
    assert_equal "arn:aws:iam::111122223333:user/alice", grant.principal_arn
    RubyCdk::Test.template(stack).resource_count_is("AWS::IAM::Policy", 0)
  end

  def test_bad_names_and_seconds_are_refused
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SQS::Queue.new(self, "Queue", queue_name: 42) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SQS::Queue.new(self, "Queue", visibility_timeout: 0) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SQS::Queue.new(self, "Queue", retention: -1) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SNS::Topic.new(self, "Topic", topic_name: 42) }
    end
  end

  private

  # One stack in an App with the test env, whose build is the block. Answers
  # [stack, the block's value].
  def build_stack(&body)
    app = build_app(env: TEST_ENV)
    value = nil
    built = RubyCdk::Stack.new(app, "Stack") do
      value = instance_eval(&body)
    end
    [ built, value ]
  end

  def template(stack)
    RubyCdk::Test.template(stack)
  end
end
