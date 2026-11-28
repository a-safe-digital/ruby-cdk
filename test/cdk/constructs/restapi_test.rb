# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/aws-apigateway/test/restapi.test.ts,
#            packages/aws-cdk-lib/aws-apigateway/test/lambda-api.test.ts and
#            packages/aws-cdk-lib/aws-apigateway/test/integrations/lambda.test.ts,
#            in aws/aws-cdk
#   Commit:  c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-27)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origins have 85 cases (80 declarations, two test.each tables of two and
# three rows), 13 cases and 10 cases: 108 between them. The construct behind
# this file is the CDK's LambdaRestApi over the RestApi it extends - the REST
# API with the Lambda proxy - which is the slice of the three files this wave
# carries.
#
# What changed to get there:
#
#   - The origin's `new cdk.Stack()` is `stack` here, `Template.fromStack` is
#     `template`; the logical ID is the ids above the resource joined, never
#     hashed (D-004, D-029): lambdarestapiAAD10924 is lambdarestapiResource.
#   - The origin's `code: lambda.Code.fromInline('boom')` and a runtime are a
#     Hash in CloudFormation's Code shape here, and the runtime is this
#     tool's default (architecture section 21).
#   - The integration URI is one Fn::Sub over the pseudo parameters, where
#     the CDK renders Fn::Join over the same five parts.
#   - A construct id here must be alphanumeric, where the CDK hashes
#     whatever it is given: lambdarestapi for the origin's lambda-rest-api.
#
# Not ported, with the reason:
#
#   Not ported because this tool does not have the feature:
#   - everything the plain RestApi surface carries and this construct does
#     not: addResource and addMethod (the proxy is fixed here), resource
#     paths and their validation, defaultIntegration and
#     defaultMethodOptions at any level, models, api keys, request
#     validators, usage plans, base-path mappings, domain names, access
#     logging, CORS preflight, request/response shapes of a method,
#     methodResponses, authorizers, gateway responses, binary media types,
#     minimum compression, endpoint types and configurations, policies,
#     cloneFrom, parameters, failOnWarnings, disableExecuteApiEndpoint,
#     SpecRestApi with its apiDefinition and mode table, fromRestApiId and
#     fromRestApiAttributes, executeApiArn and urlForPath's guards, metrics,
#     deployOptions and their stage methods matrix, retainDeployments,
#     isRestApi and defaultChild. Each arrives with the construct it needs;
#     the L1 resources remain the way to write one.
#   - the CloudWatch role, the AWS::ApiGateway::Account and the cases around
#     them (created by default, disabled by feature flag, with a removal
#     policy). This tool writes neither: an account-wide effect per API is
#     not a safe default to write silently (architecture section 21), so the
#     ported template has no role, no Account and no DependsOn on the stage
#     from one.
#   - the Deployment cases that read its logical id and its description
#     source: the id here is the ids in front plus a short hash of the
#     method set, the CDK's one hashed logical id (deployment.ts:63-77;
#     architecture section 21).
#   - lambda-api.test.ts beyond the one case ported: proxy: false and the
#     model it asks the user to define, the AWS_PROXY-always case beside it,
#     options.defaultIntegration, CORS with and without
#     defaultMethodOptions, integrationOptions (allowTestInvoke,
#     scopePermissionToMethod, proxy mapping), the function Alias case, and
#     the deployOptions-variables validation. A proxy is always on here and
#     no integration options are taken; the permission is always the
#     API-scoped one.
#   - the integrations file's per-method permission cases (the method-scoped
#     SourceArn, the console's test invoke, the permission reuse across
#     integrations). The permission here is the CDK's API-scoped one,
#     written once for the whole API (architecture section 21).
#
# The fifth test is this tool's own, no case of the origins: the function of
# the sandbox run of 2026-11-27 used twice, two APIs against it, so the D-029
# snapshot pins the two permissions and their ids.
#
# Parity: 108 cases in the origin; 4 ported; 104 not ported; 5 tests.

require "test_helper"
require "support/cdk_constructs"

class CdkConstructsRestApiTest < CdkConstructs::TestCase
  def test_lambda_rest_api_defines_a_rest_api_with_lambda_proxy_integration
    # Changed: the Fn::Sub URI and this tool's logical ids and code shape
    # (see the header); the origin's "can't customize further" throw is not
    # ported - there is no addResource to call.
    built = stack do
      handler = RubyCdk::Lambda::Function.new(self, "handler",
        code: { "ZipFile" => "boom" }, handler: "index.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "lambdarestapi", handler: handler)
    end
    template = template(built)

    template.has_resource_properties("AWS::ApiGateway::Resource", {
      "PathPart" => "{proxy+}"
    })
    template.has_resource_properties("AWS::ApiGateway::Method", {
      "HttpMethod" => "ANY",
      "ResourceId" => { "Ref" => "lambdarestapiProxy" },
      "RestApiId" => { "Ref" => "lambdarestapiResource" },
      "AuthorizationType" => "NONE",
      "Integration" => {
        "IntegrationHttpMethod" => "POST",
        "Type" => "AWS_PROXY",
        "Uri" => {
          "Fn::Sub" => [
            "arn:${AWS::Partition}:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${FunctionArn}/invocations",
            { "FunctionArn" => { "Fn::GetAtt" => [ "handlerResource", "Arn" ] } }
          ]
        }
      }
    })
  end

  def test_rest_api_name_is_set_correctly
    # Changed: the origin reads myapi.restApiName off the construct; the same
    # two facts are read off the synthesized templates here.
    built = stack do
      handler = RubyCdk::Lambda::Function.new(self, "handler",
        code: { "ZipFile" => "boom" }, handler: "index.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "myapi", handler: handler)
      RubyCdk::ApiGateway::RestApi.new(self, "yourapi", handler: handler, rest_api_name: "namedapi")
    end
    template = template(built)

    template.has_resource_properties("AWS::ApiGateway::RestApi", { "Name" => "myapi" })
    template.has_resource_properties("AWS::ApiGateway::RestApi", { "Name" => "namedapi" })
  end

  def test_name_is_defaulted_to_resource_physical_name
    # Changed: the origin passes deploy: false and cloudWatchRole: false,
    # which are not options here - the deployment is always made and no
    # CloudWatch role is ever written (see the header). The name default, the
    # construct's id, is the case.
    built = stack do
      handler = RubyCdk::Lambda::Function.new(self, "handler",
        code: { "ZipFile" => "boom" }, handler: "index.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "restapi", handler: handler)
    end

    template(built).has_resource_properties("AWS::ApiGateway::RestApi", {
      "Name" => "restapi"
    })
  end

  def test_scope_permission_to_method_set_to_false_creates_api_scoped_permission
    # Changed: this construct always writes the API-scoped permission - there
    # are no integration options here (see the header) - and the origin's
    # Fn::Join over the five parts is one Fn::Sub over the same parts, as the
    # SSM parameter ARN is (architecture section 21).
    built = stack do
      handler = RubyCdk::Lambda::Function.new(self, "handler",
        code: { "ZipFile" => "foo" }, handler: "index.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "myapi", handler: handler)
    end

    template(built).resource_count_is("AWS::Lambda::Permission", 1)
    template(built).has_resource_properties("AWS::Lambda::Permission", {
      "Action" => "lambda:InvokeFunction",
      "FunctionName" => { "Fn::GetAtt" => [ "handlerResource", "Arn" ] },
      "Principal" => "apigateway.amazonaws.com",
      "SourceArn" => {
        "Fn::Sub" => [
          "arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${__ApiId}/*/*/*",
          { "__ApiId" => { "Ref" => "myapiResource" } }
        ]
      }
    })
  end

  def test_the_api_and_its_function_used_twice_get_two_distinct_permissions
    # This tool's own case (see the header): one function, two APIs against it,
    # the shape the sandbox run of 2026-11-27 proved. D-029 joins the ids in
    # front of each resource's own, so both permissions sit under the
    # function's id and each names its own API in the SourceArn.
    built = stack do
      handler = RubyCdk::Lambda::Function.new(self, "handler",
        code: { "ZipFile" => "boom" }, handler: "index.handler")
      RubyCdk::ApiGateway::RestApi.new(self, "oneapi", handler: handler)
      RubyCdk::ApiGateway::RestApi.new(self, "twoapi", handler: handler)
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "handlerApiPermissiononeapiResource" => {
          "Type" => "AWS::Lambda::Permission",
          "Properties" => {
            "Action" => "lambda:InvokeFunction",
            "FunctionName" => { "Fn::GetAtt" => [ "handlerResource", "Arn" ] },
            "Principal" => "apigateway.amazonaws.com",
            "SourceArn" => {
              "Fn::Sub" => [
                "arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${__ApiId}/*/*/*",
                { "__ApiId" => { "Ref" => "oneapiResource" } }
              ]
            }
          }
        },
        "handlerApiPermissiontwoapiResource" => {
          "Type" => "AWS::Lambda::Permission",
          "Properties" => {
            "Action" => "lambda:InvokeFunction",
            "FunctionName" => { "Fn::GetAtt" => [ "handlerResource", "Arn" ] },
            "Principal" => "apigateway.amazonaws.com",
            "SourceArn" => {
              "Fn::Sub" => [
                "arn:${AWS::Partition}:execute-api:${AWS::Region}:${AWS::AccountId}:${__ApiId}/*/*/*",
                { "__ApiId" => { "Ref" => "twoapiResource" } }
              ]
            }
          }
        }
      }
    ))
  end
end
