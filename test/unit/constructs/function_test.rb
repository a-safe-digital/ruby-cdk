# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/constructs"
require "ruby_cdk/test"
require "support/core_helpers"

# This tool's own tests of the Lambda function, what no CDK case reaches here
# (docs/07-testing.md section 10): the log group that travels with the
# function, the runtime default, and the two ways the function can be used
# twice in one stack.
class ConstructsFunctionTest < CoreHelpers::TestCase
  INLINE_CODE = { "ZipFile" => "export.handler" }.freeze

  def test_the_default_runtime_is_the_one_pinned_in_the_file_header
    built, fn = build_stack do
      RubyCdk::Lambda::Function.new(self, "Fn", code: INLINE_CODE, handler: "app.handler")
    end

    assert_equal RubyCdk::Lambda::Function::DEFAULT_RUNTIME, fn.runtime
    template(built).has_resource_properties("AWS::Lambda::Function", {
      "Runtime" => RubyCdk::Lambda::Function::DEFAULT_RUNTIME
    })
  end

  def test_a_function_used_twice_carries_two_roles_two_log_groups_and_two_functions
    app = build_app(env: TEST_ENV)
    stack = RubyCdk::Stack.new(app, "stack") do
      RubyCdk::Lambda::Function.new(self, "Fn", code: INLINE_CODE, handler: "a.handler", function_name: "one")
      RubyCdk::Lambda::Function.new(self, "Fn2", code: INLINE_CODE, handler: "b.handler", function_name: "two")
    end
    template = RubyCdk::Test.template(stack)

    template.resource_count_is("AWS::Lambda::Function", 2)
    template.resource_count_is("AWS::IAM::Role", 2)
    template.resource_count_is("AWS::Logs::LogGroup", 2)
    template.has_resource_properties("AWS::Logs::LogGroup", { "LogGroupName" => "/aws/lambda/one" })
    template.has_resource_properties("AWS::Logs::LogGroup", { "LogGroupName" => "/aws/lambda/two" })
  end

  def test_a_function_without_a_name_creates_a_log_group_without_a_name
    built, = build_stack do
      RubyCdk::Lambda::Function.new(self, "Fn", code: INLINE_CODE, handler: "app.handler")
    end

    template(built).has_resource_properties("AWS::Logs::LogGroup", {
      "LogGroupName" => RubyCdk::Test.absent(),
      "RetentionInDays" => 731
    })
  end

  def test_a_role_given_to_the_function_is_used_not_replaced
    built, (role, fn) = build_stack do
      role = RubyCdk::IAM::Role.new(self, "Custom", assumed_by: "lambda.amazonaws.com")
      fn = RubyCdk::Lambda::Function.new(self, "Fn", code: INLINE_CODE, handler: "app.handler", role: role)
      [ role, fn ]
    end

    assert_equal role, fn.role
    template(built).has_resource_properties("AWS::Lambda::Function", {
      "Role" => { "Fn::GetAtt" => [ "CustomResource", "Arn" ] }
    })
    template(built).resource_count_is("AWS::IAM::Role", 1)
  end

  def test_a_grant_to_the_function_s_role_lands_on_the_service_role
    built, fn = build_stack do
      RubyCdk::Lambda::Function.new(self, "Fn", code: INLINE_CODE, handler: "app.handler")
    end

    grant = fn.grant_invoke(fn.role)

    assert grant.applied?
    template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ {
          "Action" => "lambda:InvokeFunction",
          "Effect" => "Allow",
          "Resource" => [
            { "Fn::Join" => [ "", [ { "Fn::GetAtt" => [ "FnResource", "Arn" ] }, ":*" ] ] },
            { "Fn::GetAtt" => [ "FnResource", "Arn" ] }
          ]
        } ],
        "Version" => "2012-10-17"
      },
      "Roles" => [ { "Ref" => "FnServiceRoleResource" } ]
    })
  end

  def test_code_that_is_neither_an_asset_nor_a_hash_is_refused
    error = assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::Lambda::Function.new(self, "Fn", code: "app.rb", handler: "app.handler") }
    end

    assert_match(/the code must be an asset of the stack/, error.message)
  end

  def test_an_empty_runtime_or_handler_is_refused
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::Lambda::Function.new(self, "Fn", code: INLINE_CODE, handler: "") }
    end
    assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::Lambda::Function.new(self, "Fn", code: INLINE_CODE, handler: "app.handler", runtime: "") }
    end
  end

  def test_the_log_retention_travels_to_the_log_group
    built, fn = build_stack do
      RubyCdk::Lambda::Function.new(self, "Fn", code: INLINE_CODE, handler: "app.handler", function_name: "fn", log_retention: 14)
    end

    assert_equal 14, fn.log_group.retention_days
    template(built).has_resource_properties("AWS::Logs::LogGroup", { "RetentionInDays" => 14 })
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
