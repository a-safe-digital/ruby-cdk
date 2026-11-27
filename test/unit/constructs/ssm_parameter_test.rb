# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/constructs"
require "ruby_cdk/test"
require "support/core_helpers"

# This tool's own tests of the SSM parameter, what no CDK case reaches here
# (docs/07-testing.md section 10): twice in one stack, the unnamed resource,
# the one-class two-types shape, SecureString's refusal, and the grants to an
# ARN principal.
class ConstructsSSMParameterTest < CoreHelpers::TestCase
  def test_a_parameter_used_twice_carries_two_distinct_resources
    app = build_app(env: TEST_ENV)
    stack = RubyCdk::Stack.new(app, "stack") do
      RubyCdk::SSM::Parameter.new(self, "One", value: "a", name: "one")
      RubyCdk::SSM::Parameter.new(self, "Two", value: "b", name: "two")
    end
    template = RubyCdk::Test.template(stack)

    template.resource_count_is("AWS::SSM::Parameter", 2)
    template.has_resource_properties("AWS::SSM::Parameter", { "Name" => "one", "Value" => "a" })
    template.has_resource_properties("AWS::SSM::Parameter", { "Name" => "two", "Value" => "b" })
  end

  def test_a_parameter_without_a_name_refers_to_its_resource
    _, parameter = build_stack do
      RubyCdk::SSM::Parameter.new(self, "One", value: "a")
    end

    assert_equal({ "Ref" => "OneResource" }, parameter.parameter_name)
    assert_equal(
      { "Fn::Sub" => [
        "arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter/${ParameterName}",
        { "ParameterName" => { "Ref" => "OneResource" } }
      ] },
      parameter.arn
    )
  end

  def test_a_grant_to_an_arn_principal_is_returned_unapplied
    stack, parameter = build_stack do
      RubyCdk::SSM::Parameter.new(self, "One", value: "a")
    end

    grant = parameter.grant_read("arn:aws:iam::111122223333:user/alice")

    refute grant.applied?
    assert_equal "arn:aws:iam::111122223333:user/alice", grant.principal_arn
    RubyCdk::Test.template(stack).resource_count_is("AWS::IAM::Policy", 0)
  end

  def test_grant_write_carries_the_put_parameter_action
    built, = build_stack do
      parameter = RubyCdk::SSM::Parameter.new(self, "One", value: "a")
      writer = RubyCdk::IAM::Role.new(self, "Writer", assumed_by: "lambda.amazonaws.com")
      parameter.grant_write(writer)
    end

    RubyCdk::Test.template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ {
          "Action" => "ssm:PutParameter",
          "Effect" => "Allow",
          "Resource" => {
            "Fn::Sub" => [
              "arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter/${ParameterName}",
              { "ParameterName" => { "Ref" => "OneResource" } }
            ]
          }
        } ]
      },
      "Roles" => [ { "Ref" => "WriterResource" } ]
    })
  end

  def test_secure_string_is_refused_with_the_kms_implication
    error = assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SSM::Parameter.new(self, "One", value: "a", type: :secure_string) }
    end

    assert_match(/type takes :string or :string_list/, error.message)
    assert_match(/kms:Decrypt/, error.message)
  end

  def test_an_unknown_type_tier_or_data_type_is_refused
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SSM::Parameter.new(self, "One", value: "a", type: :secure) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SSM::Parameter.new(self, "One", value: "a", tier: :premium) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SSM::Parameter.new(self, "One", value: "a", data_type: "aws:ec2:ami") }
    end
  end

  def test_a_string_parameter_takes_one_value_and_a_list_takes_an_array
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SSM::Parameter.new(self, "One", value: [ "a", "b" ]) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SSM::Parameter.new(self, "One", value: 42) }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SSM::Parameter.new(self, "One", value: [ "a", 42 ], type: :string_list) }
    end
  end

  def test_an_allowed_pattern_that_is_not_a_regular_expression_is_refused
    error = assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::SSM::Parameter.new(self, "One", value: "a", allowed_pattern: "(bar") }
    end

    assert_match(/allowed_pattern is not a regular expression/, error.message)
  end

  def test_an_intrinsic_value_passes_the_pattern_check_untouched
    built, = build_stack do
      RubyCdk::SSM::Parameter.new(self, "One", value: Fn.sub("v-${AWS::StackName}"), allowed_pattern: "^v-")
    end

    RubyCdk::Test.template(built).has_resource_properties("AWS::SSM::Parameter", {
      "Value" => { "Fn::Sub" => "v-${AWS::StackName}" }
    })
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
