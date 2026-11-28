# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/constructs"
require "ruby_cdk/test"
require "support/core_helpers"

# This tool's own tests of the EventBridge rule, what no CDK case reaches here
# (docs/07-testing.md section 10): twice in one stack, a Lambda function as
# the target with its Targets entry, the schedule taken as a bare expression
# String, and the pattern standing behind its Lazy.
class ConstructsEventsRuleTest < CoreHelpers::TestCase
  def test_a_rule_used_twice_carries_two_distinct_resources
    app = build_app(env: TEST_ENV)
    stack = RubyCdk::Stack.new(app, "stack") do
      RubyCdk::Events::Rule.new(self, "One", rule_name: "one",
        schedule: RubyCdk::Events::Schedule.rate(10, :minutes))
      RubyCdk::Events::Rule.new(self, "Two", rule_name: "two",
        schedule: RubyCdk::Events::Schedule.rate(5, :minutes))
    end
    template = RubyCdk::Test.template(stack)

    template.resource_count_is("AWS::Events::Rule", 2)
    template.has_resource_properties("AWS::Events::Rule", { "Name" => "one" })
    template.has_resource_properties("AWS::Events::Rule", { "Name" => "two" })
  end

  def test_a_rule_without_a_name_refers_to_its_resource
    _, rule = build_stack do
      RubyCdk::Events::Rule.new(self, "One", schedule: "rate(1 minute)")
    end

    assert_equal({ "Ref" => "OneResource" }, rule.rule_name)
    assert_equal({ "Fn::GetAtt" => [ "OneResource", "Arn" ] }, rule.arn)
  end

  def test_a_lambda_function_as_the_target_carries_its_arn
    built, rule = build_stack do
      function = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" }, handler: "app.handler")
      rule = RubyCdk::Events::Rule.new(self, "Rule", schedule: "rate(1 minute)")
      rule.add_target(function)
      rule
    end

    assert_equal [ { "Id" => "Target0", "Arn" => { "Fn::GetAtt" => [ "FnResource", "Arn" ] } } ], rule.targets
    RubyCdk::Test.template(built).has_resource_properties("AWS::Events::Rule", {
      "Targets" => [ { "Id" => "Target0", "Arn" => { "Fn::GetAtt" => [ "FnResource", "Arn" ] } } ]
    })
  end

  def test_add_target_writes_the_permission_on_the_function
    built, = build_stack do
      function = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" }, handler: "app.handler")
      RubyCdk::Events::Rule.new(self, "Rule", schedule: "rate(1 minute)").add_target(function)
    end

    # The CDK's addLambdaPermission writes an AWS::Lambda::Permission; so
    # does add_target now (architecture section 21, amended 2026-11-28): the
    # statement lands on the function's resource policy, where the events
    # service - a principal without a policy of its own - can be read.
    RubyCdk::Test.template(built).has_resource_properties("AWS::Lambda::Permission", {
      "Action" => "lambda:InvokeFunction",
      "FunctionName" => { "Fn::GetAtt" => [ "FnResource", "Arn" ] },
      "Principal" => "events.amazonaws.com",
      "SourceArn" => { "Fn::GetAtt" => [ "RuleResource", "Arn" ] }
    })
  end

  def test_a_target_without_an_arn_is_refused
    error = assert_raises(RubyCdk::UsageError) do
      build_stack do
        RubyCdk::Events::Rule.new(self, "Rule", schedule: "rate(1 minute)").add_target("arn:of:something")
      end
    end

    assert_match(/add_target takes a function with an arn/, error.message)
  end

  def test_the_pattern_and_the_targets_are_read_after_the_rule_was_built
    built, = build_stack do
      function = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" }, handler: "app.handler")
      rule = RubyCdk::Events::Rule.new(self, "Rule")
      rule.add_target(function)
      rule.add_event_pattern(source: [ "aws.ec2" ])
      rule
    end

    RubyCdk::Test.template(built).template_matches({
      "AWSTemplateFormatVersion" => "2010-09-09",
      "Resources" => {
        "RuleResource" => {
          "Type" => "AWS::Events::Rule",
          "Properties" => {
            "State" => "ENABLED",
            "EventPattern" => { "source" => [ "aws.ec2" ] },
            "Targets" => [ { "Id" => "Target0", "Arn" => { "Fn::GetAtt" => [ "FnResource", "Arn" ] } } ]
          }
        }
      }
    })
  end

  def test_a_schedule_taken_as_a_bare_expression_string
    built, = build_stack do
      RubyCdk::Events::Rule.new(self, "Rule", schedule: "rate(1 minute)")
    end

    RubyCdk::Test.template(built).has_resource_properties("AWS::Events::Rule", {
      "ScheduleExpression" => "rate(1 minute)"
    })
  end

  def test_a_bare_value_in_a_pattern_field_is_refused
    error = assert_raises(RubyCdk::UsageError) do
      build_stack do
        RubyCdk::Events::Rule.new(self, "Rule", event_pattern: { source: "aws.ec2" })
      end
    end

    assert_match(/Invalid event pattern field \{ source: "aws\.ec2" \}\. All fields must be arrays/, error.message)
  end

  def test_a_type_mismatch_between_pattern_adds_is_refused
    error = assert_raises(RubyCdk::UsageError) do
      build_stack do
        rule = RubyCdk::Events::Rule.new(self, "Rule", event_pattern: { detail: { foo: [ "a" ] } })
        rule.add_event_pattern(detail: { foo: { bar: [ "b" ] } })
      end
    end

    assert_match(/Type mismatch between existing pattern/, error.message)
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
