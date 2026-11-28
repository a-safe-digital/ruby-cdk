# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/constructs"
require "ruby_cdk/test"
require "support/core_helpers"

# This tool's own tests of the REST API, what no CDK case reaches here
# (docs/07-testing.md section 10): twice in one stack, the resources the
# construct does not write (no Account), and the refusals.
class ConstructsRestApiTest < CoreHelpers::TestCase
  def test_an_api_used_twice_carries_two_distinct_sets_of_resources
    app = build_app(env: TEST_ENV)
    stack = RubyCdk::Stack.new(app, "stack") do
      handler = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" }, handler: "app.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "One", handler: handler, rest_api_name: "one")
      RubyCdk::ApiGateway::RestApi.new(self, "Two", handler: handler, rest_api_name: "two")
    end
    template = RubyCdk::Test.template(stack)

    template.resource_count_is("AWS::ApiGateway::RestApi", 2)
    template.resource_count_is("AWS::ApiGateway::Resource", 2)
    template.resource_count_is("AWS::ApiGateway::Method", 4)
    template.resource_count_is("AWS::ApiGateway::Deployment", 2)
    template.resource_count_is("AWS::ApiGateway::Stage", 2)
    template.has_resource_properties("AWS::ApiGateway::RestApi", { "Name" => "one" })
    template.has_resource_properties("AWS::ApiGateway::RestApi", { "Name" => "two" })
    # One permission per API (D-029): each names its own API in the SourceArn.
    template.resource_count_is("AWS::Lambda::Permission", 2)
    template.has_resource_properties("AWS::Lambda::Permission", {
      "SourceArn" => {
        "Fn::Sub" => [
          "arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${__ApiId}/*/*/*",
          { "__ApiId" => { "Ref" => "OneResource" } }
        ]
      }
    })
    template.has_resource_properties("AWS::Lambda::Permission", {
      "SourceArn" => {
        "Fn::Sub" => [
          "arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${__ApiId}/*/*/*",
          { "__ApiId" => { "Ref" => "TwoResource" } }
        ]
      }
    })
  end

  def test_an_api_without_a_name_is_named_after_its_id
    built, api = build_stack do
      handler = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" }, handler: "app.handler")
      api = RubyCdk::ApiGateway::RestApi.new(self, "restapi", handler: handler)
      api
    end

    assert_equal "restapi", api.rest_api_name
    RubyCdk::Test.template(built).has_resource_properties("AWS::ApiGateway::RestApi", {
      "Name" => "restapi"
    })
  end

  def test_the_deployment_depends_on_both_methods_and_the_stage_deploys_it
    built, = build_stack do
      handler = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" }, handler: "app.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "Api", handler: handler)
    end

    RubyCdk::Test.template(built).has_resource("AWS::ApiGateway::Deployment",
      "DependsOn" => [ "ApiRootMethod", "ApiProxyMethod" ])
    deployment_id = RubyCdk::Test.template(built).to_json["Resources"].keys.find { |id| id.start_with?("ApiDeployment") }
    RubyCdk::Test.template(built).has_resource_properties("AWS::ApiGateway::Stage", {
      "StageName" => "prod",
      "DeploymentId" => { "Ref" => deployment_id }
    })
  end

  def test_no_account_is_written
    built, = build_stack do
      handler = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" }, handler: "app.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "Api", handler: handler)
    end
    template = RubyCdk::Test.template(built)

    template.resource_count_is("AWS::ApiGateway::Account", 0)
    template.resource_count_is("AWS::IAM::Role", 1) # the function's own service role
  end

  def test_the_deployment_id_follows_the_api_and_its_methods
    # The same API built twice: the same deployment id, wherever the code
    # runs. A changed API - here the name - a changed deployment, so that
    # CloudFormation makes a new one and the stage moves to it.
    one = build_stack do
      handler = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" }, handler: "app.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "Api", handler: handler)
    end
    two = build_stack do
      handler = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" }, handler: "app.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "Api", handler: handler)
    end
    three = build_stack do
      handler = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" }, handler: "app.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "Api", handler: handler, rest_api_name: "renamed")
    end

    ids = [ one, two, three ].map do |(built, _)|
      RubyCdk::Test.template(built).to_json["Resources"].keys.find { |id| id.start_with?("ApiDeployment") }
    end
    assert_equal ids[0], ids[1]
    refute_equal ids[0], ids[2]
  end

  def test_a_handler_without_an_arn_and_a_wrong_authorization_are_refused
    assert_raises(RubyCdk::UsageError) do
      build_stack do
        RubyCdk::ApiGateway::RestApi.new(self, "Api", handler: "arn:aws:lambda:...")
      end
    end
    error = assert_raises(RubyCdk::UsageError) do
      build_stack do
        handler = RubyCdk::Lambda::Function.new(self, "Fn",
          code: { "ZipFile" => "x" }, handler: "app.handler")
        RubyCdk::ApiGateway::RestApi.new(self, "Api", handler: handler, authorization: :openid)
      end
    end

    assert_match(/authorization takes/, error.message)
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
