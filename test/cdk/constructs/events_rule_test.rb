# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/aws-events/test/rule.test.ts and
#            packages/aws-cdk-lib/aws-events-targets/test/lambda/lambda.test.ts,
#            in aws/aws-cdk
#   Commit:  c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-27)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 41 test declarations and one test.each table of two rows
# (L1 and L2): 43 cases; the targets file has 10: 53 between them. Each
# ported one keeps its name, as a comment above the test, and what it
# expects. What changed to get there:
#
#   - The origin's `new cdk.Stack()` is `stack` here, `Template.fromStack` is
#     `template`; the logical ID is the ids above the resource joined, never
#     hashed (D-004, D-029): MyRuleA44AB831 is MyRuleResource.
#   - `Schedule.rate(cdk.Duration.minutes(10))` is `Schedule.rate(10,
#     :minutes)` here: this tool has no Duration, and the number and the unit
#     are given directly (the three units the CDK's literal path writes).
#   - The construct-level checks the CDK runs at synthesis - a rule name
#     check, the more-than-five-targets check, the eventBus-and-schedule
#     refusal - run at construction here: building is immediate, and a
#     refusal names the construct instead of the synthesis (the
#     neither-pattern-nor-schedule check is the one that stays a synthesis
#     failure, because a rule may be built bare and given its pattern after;
#     the Lazy that stands in for the pattern raises it, and the resolver
#     makes it an issue at the EventPattern's place).
#   - The origin's `eventBus: new EventBus(...)` is `event_bus_name:` here:
#     this wave carries no EventBus construct, the rule takes the bus's name.
#   - The origin's targets carry arn: `SomeTarget` fakes; here a target is
#     anything with an arn and add_permission, the FakeTarget stub in these
#     tests or a Lambda::Function in an app. The Lambda target's permission
#     is written under the function's logical id (D-029), where the CDK's
#     sits under the rule, so the permission's id names the rule.
#
# Not ported, with the reason:
#
#   Not ported because this tool does not have the feature:
#   - rule displays warning when minutes are not included in cron, and rule
#     does not display warning when minute is set to * in cron. The CDK's
#     synth-time annotations have no counterpart here; the template is the
#     whole output (aws-events/lib/schedule.ts:69-72 is the source).
#   - get rate as token. No token Durations: a rate is a number and a unit.
#   - targets can be added via props or addTarget with input transformer;
#     input template can contain tokens. No RuleTargetInput: a target here is
#     the Id and the Arn, and custom input arrives with the target props.
#   - target can declare role which will be used; can specify roleArn. The
#     rule's RoleArn prop and target roles arrive with the constructs that
#     need them; a rule of this wave takes no role.
#   - in cross-account scenario, target role is only used in target account;
#     the whole cross-account and cross-region describe (nine cases: requires
#     that the source/target stack specify a concrete account or region,
#     creates cross-account targets, cross-region targets, do not create
#     duplicated targets, requires that the target is not imported, requires
#     that the source and target stacks be part of the same App, generates
#     the correct rules in the source and target stacks twice). Cross-stack
#     target wiring is not in this wave; a target is a function of the rule's
#     own stack.
#   - asEventRuleTarget can use the ruleArn and a uniqueId of the rule. No
#     IRuleTarget interface: there is no target kind to implement it.
#   - fromEventRuleArn, sets account/region for imported rule env (three).
#     Imports of existing rules are lookups (D-022).
#   - can add multiple targets with the same id. Targets take no id here:
#     each gets the CDK's auto-generated Target<N>.
#   - sqsParameters and redshiftDataParameters cases. No SQS or Redshift
#     target props in this wave; the Lambda target is the one carried.
#   - the test.each L1/L2 rows. Direct CfnRule construction is not a case
#     here: grants and resources go through the constructs.
#   - the lambda target's DeadLetterQueue cases (three: the queue policy, the
#     region refusal, the cross-account warning) and its retry-policy cases
#     (two). No DLQ or retry props on a target here; they arrive with the
#     target props.
#   - adding the same singleton function as target creates the permission only
#     once. No singleton function: two Functions are two constructs, and the
#     permission sits under each one's own id (D-029).
#   - lambda handler and cloudwatch event across stacks. Cross-stack target
#     wiring is not in this wave, as the rule.test.ts cases above.
#
# Parity: 53 cases in the origin; 18 ported; 35 not ported; 18 tests.

require "test_helper"
require "support/cdk_constructs"

class CdkConstructsEventsRuleTest < CdkConstructs::TestCase
  def test_default_rule
    built = stack do
      RubyCdk::Events::Rule.new(self, "MyRule",
        schedule: RubyCdk::Events::Schedule.rate(10, :minutes))
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyRuleResource" => {
          "Type" => "AWS::Events::Rule",
          "Properties" => {
            "ScheduleExpression" => "rate(10 minutes)",
            "State" => "ENABLED"
          }
        }
      }
    ))
  end

  def test_can_get_rule_name
    built = stack do
      rule = RubyCdk::Events::Rule.new(self, "MyRule",
        schedule: RubyCdk::Events::Schedule.rate(10, :minutes))
      resource("Res", "Test::Resource", RuleName: rule.rule_name)
    end

    template(built).has_resource_properties("Test::Resource", {
      "RuleName" => { "Ref" => "MyRuleResource" }
    })
  end

  def test_rule_cannot_have_more_than_5_targets
    # Changed: the check is at construction, not at synthesis (see header),
    # and the fake carries add_permission, the method a real function has
    # that add_target calls to write the permission.
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        rule = RubyCdk::Events::Rule.new(self, "MyRule",
          schedule: RubyCdk::Events::Schedule.rate(10, :minutes))
        6.times { |index| rule.add_target(FakeTarget.new("arn:of:#{index}")) }
      end
    end

    assert_match(/Event rule cannot have more than 5 targets./, error.message)
  end

  def test_seconds_is_not_an_allowed_value_for_schedule_rate
    # Changed: the CDK refuses through Duration's units; this tool's rate
    # takes the unit and names the three it takes.
    error = assert_raises(RubyCdk::UsageError) do
      RubyCdk::Events::Schedule.rate(5, :seconds)
    end

    assert_match(/Schedule.rate takes/, error.message)
  end

  def test_millis_is_not_an_allowed_value_for_schedule_rate
    error = assert_raises(RubyCdk::UsageError) do
      RubyCdk::Events::Schedule.rate(5, :millis)
    end

    assert_match(/Schedule.rate takes/, error.message)
  end

  def test_rule_with_physical_name
    built = stack do
      RubyCdk::Events::Rule.new(self, "MyRule",
        rule_name: "PhysicalName",
        schedule: RubyCdk::Events::Schedule.rate(10, :minutes))
    end

    template(built).has_resource_properties("AWS::Events::Rule", {
      "Name" => "PhysicalName"
    })
  end

  def test_fails_synthesis_if_neither_event_pattern_nor_schedule_expression_are_specified
    # Changed: the check is a Lazy's refusal at resolve, so the synthesis of
    # the template raises, where the origin's app.synth() does (see header).
    error = assert_raises(RubyCdk::ValidationError) do
      template(stack do
        RubyCdk::Events::Rule.new(self, "Rule")
      end)
    end

    assert_match(/Either 'eventPattern' or 'schedule' must be defined/, error.message)
  end

  def test_fails_when_rule_name_is_less_than_1_chars
    # Changed: at construction, not at synthesis (see header).
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::Events::Rule.new(self, "Rule", rule_name: "",
          schedule: RubyCdk::Events::Schedule.rate(10, :minutes))
      end
    end

    assert_match(/Event rule name must be between 1 and 64 characters./, error.message)
  end

  def test_fails_when_rule_name_is_longer_than_64_chars
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::Events::Rule.new(self, "Rule", rule_name: "a" * 65,
          schedule: RubyCdk::Events::Schedule.rate(10, :minutes))
      end
    end

    assert_match(/Event rule name must be between 1 and 64 characters./, error.message)
  end

  def test_fails_when_rule_name_contains_invalid_characters
    # Changed: the construct id stays valid here (this tool's ids are
    # narrower than the CDK's), the invalid character goes into the name only.
    [ " ", "\n", "\r", "[", "]", "<", ">", "$" ].each do |invalid_char|
      error = assert_raises(RubyCdk::UsageError) do
        stack do
          RubyCdk::Events::Rule.new(self, "Rule", rule_name: "Rule#{invalid_char}",
            schedule: RubyCdk::Events::Schedule.rate(10, :minutes))
        end
      end

      assert_match(/can contain only letters, numbers, periods, hyphens, or underscores with no spaces./, error.message)
    end
  end

  def test_add_event_pattern_can_be_used_to_add_filters
    built = stack do
      rule = RubyCdk::Events::Rule.new(self, "MyRule")
      rule.add_event_pattern(
        account: [ "12345" ],
        detail: { foo: [ "hello", "bar", "hello" ] })
      rule.add_event_pattern(
        source: [ "aws.source" ],
        detail: { foo: [ "bar", "hello" ], goo: { hello: [ "world" ] } })
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyRuleResource" => {
          "Type" => "AWS::Events::Rule",
          "Properties" => {
            "EventPattern" => {
              "account" => [ "12345" ],
              "detail" => { "foo" => [ "hello", "bar" ], "goo" => { "hello" => [ "world" ] } },
              "source" => [ "aws.source" ]
            },
            "State" => "ENABLED"
          }
        }
      }
    ))
  end

  def test_add_event_pattern_can_de_duplicate_filters_and_keep_the_order
    built = stack do
      rule = RubyCdk::Events::Rule.new(self, "MyRule")
      rule.add_event_pattern(detail_type: [ "AWS API Call via CloudTrail", "AWS API Call via CloudTrail" ])
      rule.add_event_pattern(detail_type: [ "EC2 Instance State-change Notification", "AWS API Call via CloudTrail" ])
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyRuleResource" => {
          "Type" => "AWS::Events::Rule",
          "Properties" => {
            "EventPattern" => {
              "detail-type" => [ "AWS API Call via CloudTrail", "EC2 Instance State-change Notification" ]
            },
            "State" => "ENABLED"
          }
        }
      }
    ))
  end

  def test_rule_can_be_disabled
    built = stack do
      RubyCdk::Events::Rule.new(self, "Rule", schedule: RubyCdk::Events::Schedule.expression("foom"),
        enabled: false)
    end

    template(built).has_resource_properties("AWS::Events::Rule", {
      "State" => "DISABLED"
    })
  end

  def test_associate_rule_with_event_bus
    # Changed: the origin associates an EventBus construct; the rule takes the
    # bus's name here (see header).
    built = stack do
      RubyCdk::Events::Rule.new(self, "MyRule", event_bus_name: "bus-name",
        event_pattern: { detail: [ "detail" ] })
    end

    template(built).has_resource_properties("AWS::Events::Rule", {
      "EventBusName" => "bus-name"
    })
  end

  def test_throws_with_event_bus_and_schedule
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::Events::Rule.new(self, "MyRule",
          schedule: RubyCdk::Events::Schedule.rate(10, :minutes), event_bus_name: "bus-name")
      end
    end

    assert_match(/Cannot associate rule with 'eventBus' when using 'schedule'/, error.message)
  end

  def test_use_lambda_as_an_event_rule_target
    # Changed: the logical IDs (MyLambdaCCE802FB is MyLambdaResource), and two
    # add_target calls where the origin wraps the function in its target
    # object (see header). One permission per rule and function; the id names
    # the rule, where the CDK's names the handler.
    built = stack do
      handler = RubyCdk::Lambda::Function.new(self, "MyLambda",
        code: { "ZipFile" => "foo" }, handler: "bar")
      rule1 = RubyCdk::Events::Rule.new(self, "Rule",
        schedule: RubyCdk::Events::Schedule.rate(1, :minutes))
      rule2 = RubyCdk::Events::Rule.new(self, "Rule2",
        schedule: RubyCdk::Events::Schedule.rate(5, :minutes))
      rule1.add_target(handler)
      rule2.add_target(handler)
    end

    template(built).has_resource_properties("AWS::Lambda::Permission", {
      "Action" => "lambda:InvokeFunction",
      "FunctionName" => { "Fn::GetAtt" => [ "MyLambdaResource", "Arn" ] },
      "Principal" => "events.amazonaws.com",
      "SourceArn" => { "Fn::GetAtt" => [ "RuleResource", "Arn" ] }
    })
    template(built).has_resource_properties("AWS::Lambda::Permission", {
      "Action" => "lambda:InvokeFunction",
      "FunctionName" => { "Fn::GetAtt" => [ "MyLambdaResource", "Arn" ] },
      "Principal" => "events.amazonaws.com",
      "SourceArn" => { "Fn::GetAtt" => [ "Rule2Resource", "Arn" ] }
    })
    template(built).resource_count_is("AWS::Events::Rule", 2)
    template(built).has_resource_properties("AWS::Events::Rule", {
      "Targets" => [ { "Arn" => { "Fn::GetAtt" => [ "MyLambdaResource", "Arn" ] }, "Id" => "Target0" } ]
    })
  end

  def test_adding_same_lambda_function_as_target_multiple_times_creates_permission_only_once
    # Changed: the origin's case name says "mutiple"; the expectation is the
    # same, and there is no RuleTargetInput here (see header).
    built = stack do
      handler = RubyCdk::Lambda::Function.new(self, "MyLambda",
        code: { "ZipFile" => "foo" }, handler: "bar")
      rule = RubyCdk::Events::Rule.new(self, "Rule",
        schedule: RubyCdk::Events::Schedule.rate(1, :minutes))
      rule.add_target(handler)
      rule.add_target(handler)
    end

    template(built).resource_count_is("AWS::Lambda::Permission", 1)
  end

  def test_adding_different_lambda_functions_as_target_multiple_times_creates_multiple_permissions
    # Changed: the origin's case name says "mutiple"; the expectation is the
    # same, and there is no RuleTargetInput here (see header).
    built = stack do
      fn1 = RubyCdk::Lambda::Function.new(self, "MyLambda",
        code: { "ZipFile" => "foo" }, handler: "bar")
      fn2 = RubyCdk::Lambda::Function.new(self, "MyLambda2",
        code: { "ZipFile" => "foo" }, handler: "bar")
      rule = RubyCdk::Events::Rule.new(self, "Rule",
        schedule: RubyCdk::Events::Schedule.rate(1, :minutes))
      rule.add_target(fn1)
      rule.add_target(fn2)
    end

    template(built).resource_count_is("AWS::Lambda::Permission", 2)
  end
end

# The origin's SomeTarget: the arn, and the method add_target calls to write
# the permission (see the header).
class FakeTarget
  attr_reader :arn

  def initialize(arn)
    @arn = arn
  end

  def add_permission(*)
    nil
  end
end
