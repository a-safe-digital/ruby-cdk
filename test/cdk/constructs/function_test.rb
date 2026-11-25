# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/aws-lambda/test/function.test.ts, in aws/aws-cdk
#   Commit:  c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-25)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 204 cases. Each ported one keeps its name, as a comment above
# the test, and what it expects. What changed to get there:
#
#   - The origin's `new Stack()` is `stack` here, `Template.fromStack` is
#     `template`.
#   - `new lambda.Function(stack, id, { code, handler, runtime })` is
#     RubyCdk::Lambda::Function.new(stack, id, code:, handler:, runtime:), and
#     the runtime is the String the CDK's Runtime carries ("nodejs24.x" for its
#     NODEJS_LATEST). The code of the origin's inline cases is a Hash in
#     CloudFormation's Code shape ({"ZipFile" => "foo"}), which this tool's
#     code: takes exactly as the CDK's Code.fromInline makes there.
#   - The logical ID is the ids above the resource joined, never hashed
#     (D-004, D-029): Function76856677 is FunctionResource, MyLambda's role is
#     MyLambdaServiceRoleResource.
#   - Managed policy ARNs are written as the literal
#     arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole, where
#     the origin's is an Fn::Join over the partition: this tool's templates
#     carry no partition pseudo parameter.
#
# Changed expectations, stated next to the test:
#
#   - "default function" and "adds policy permissions": the function carries
#     DependsOn of its role and of its log group, and the stack carries the
#     function's log group - an AWS::Logs::LogGroup named
#     /aws/lambda/<function name>, kept 731 days. The CDK creates no log group
#     and depends on the role only; this tool gives every function a real log
#     group with retention (architecture section 7 wins; the row is in
#     section 21). With no function name the origin's template shows none; the
#     ported cases carry one where the log group's name needs it.
#
# Not ported, with the reason:
#
#   Not ported because this tool does not have the feature:
#   - the alias, version and currentVersion cases (adds iam:InvokeFunction on
#     versions, addAlias, invokeMethodArn, the currentVersion warnings). No
#     versions or aliases in this wave.
#   - the DLQ cases (SQS and SNS dead letter queues, nine). No DLQ props here.
#   - the tracing cases (active and pass-through). No tracing prop here.
#   - VPC, filesystem, layers, profiling, environment encryption, ephemeral
#     storage, snapstart, architecture and the rest of the prop surface. Each
#     is a prop this wave does not carry; the L1 resource: remains the way to
#     write one.
#   - fromFunctionArn / fromFunctionName / imported-function grant and
#     permission cases. Lookups of existing resources are not in 0.1.0
#     (D-022).
#   - addPermission cases (principals of every kind, sourceArn and
#     sourceAccount conditions, principalOrgID, skipPermissions warnings). The
#     CDK's addPermission writes a Lambda::Permission to the function's
#     resource policy; this tool grants to identities only, so there is no
#     Permission resource and no permission principals to parse - grant_invoke
#     is the one case of it, ported with the statement the grantee's policy
#     carries.
#   - logRetention and logGroup prop cases, and the LogRetention retry options.
#     The function's log group here is a real LogGroup construct of the stack;
#     the CDK's custom-resource route does not exist in this tool.
#   - the Runtime enum cases (invalid runtime for inline code, FROM_IMAGE,
#     custom runtime annotations, NODEJS_LATEST resolution). There is no
#     Runtime model here; the identifier is a String, by design.
#   - Code cases beyond the asset one (inline for image, s3 bucket code,
#     ECR image). The asset case is ported; the rest arrive with their
#     constructs.
#   - metrics cases. No metrics here.
#
# Parity: 204 cases in the origin; 5 ported; 199 not ported.

require "test_helper"
require "support/cdk_constructs"

class CdkConstructsFunctionTest < CdkConstructs::TestCase
  def test_default_function
    # Changed: the function carries DependsOn of its role and log group, and
    # the stack carries the function's log group (see the header).
    built = stack do
      RubyCdk::Lambda::Function.new(self, "MyLambda",
        code: { "ZipFile" => "foo" },
        handler: "index.handler",
        runtime: "nodejs24.x",
        function_name: "my-lambda")
    end

    template(built).has_resource_properties("AWS::IAM::Role", {
      "AssumeRolePolicyDocument" => {
        "Statement" => [ {
          "Action" => "sts:AssumeRole",
          "Effect" => "Allow",
          "Principal" => { "Service" => "lambda.amazonaws.com" }
        } ],
        "Version" => "2012-10-17"
      },
      "ManagedPolicyArns" => [ "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" ]
    })

    template(built).has_resource("AWS::Lambda::Function", {
      "Properties" => {
        "Code" => { "ZipFile" => "foo" },
        "Handler" => "index.handler",
        "Role" => { "Fn::GetAtt" => [ "MyLambdaServiceRoleResource", "Arn" ] },
        "Runtime" => "nodejs24.x",
        "FunctionName" => "my-lambda"
      },
      "DependsOn" => [ "MyLambdaServiceRoleResource", "MyLambdaLogGroupResource" ]
    })

    template(built).has_resource_properties("AWS::Logs::LogGroup", {
      "LogGroupName" => "/aws/lambda/my-lambda",
      "RetentionInDays" => 731
    })
  end

  def test_function_without_layers_omits_layers_property
    built = stack do
      RubyCdk::Lambda::Function.new(self, "MyLambda",
        code: { "ZipFile" => "foo" },
        handler: "index.handler",
        runtime: "nodejs24.x")
    end

    template(built).has_resource_properties("AWS::Lambda::Function", {
      "Layers" => RubyCdk::Test.absent()
    })
  end

  def test_adds_policy_permissions
    built = stack do
      RubyCdk::Lambda::Function.new(self, "MyLambda",
        code: { "ZipFile" => "foo" },
        handler: "index.handler",
        runtime: "nodejs24.x",
        function_name: "my-lambda",
        initial_policy: [ RubyCdk::IAM::PolicyStatement.new(actions: [ "*" ], resources: [ "*" ]) ])
    end

    template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [ { "Action" => "*", "Effect" => "Allow", "Resource" => "*" } ],
        "Version" => "2012-10-17"
      },
      "PolicyName" => "MyLambdaServiceRoleDefaultPolicy",
      "Roles" => [ { "Ref" => "MyLambdaServiceRoleResource" } ]
    })

    template(built).has_resource("AWS::Lambda::Function", {
      "DependsOn" => [ "MyLambdaServiceRoleResource", "MyLambdaLogGroupResource" ]
    })
  end

  def test_lambda_code_can_be_read_from_a_local_directory_via_an_asset
    # Changed: the asset bucket is this tool's own, named of the stack's env,
    # and the key is <asset hash>.zip; the hash is the bytes of the directory,
    # which the examples' snapshot tests pin. The key is matched as any value
    # here: what this case pins is that the Code names the bucket and the key,
    # not which bytes a temp directory hashes to.
    directory = handler_dir
    Dir.mkdir(directory) unless File.directory?(directory)
    File.write(File.join(directory, "index.py"), "def handler(event, context): return 42\n")

    built = stack(env: TEST_ENV) do
      RubyCdk::Lambda::Function.new(self, "MyLambda",
        code: asset.zip(directory),
        handler: "index.handler",
        runtime: "python3.9")
    end

    template(built).has_resource_properties("AWS::Lambda::Function", {
      "Code" => {
        "S3Bucket" => "ruby-cdk-assets-111122223333-eu-west-1",
        "S3Key" => RubyCdk::Test.any_value()
      },
      "Handler" => "index.handler",
      "Role" => { "Fn::GetAtt" => [ "MyLambdaServiceRoleResource", "Arn" ] },
      "Runtime" => "python3.9"
    })
  end

  def test_adds_iam_invoke_function
    # Changed: granted to a Role built in this stack (the origin's is the same,
    # an iam.Role), and the policy carries Roles; the function's logical ID is
    # FunctionResource. The statement names the qualified ARN and the plain
    # one, as the origin's does.
    built = stack do
      role = RubyCdk::IAM::Role.new(self, "Role", assumed_by: "1234")
      fn = RubyCdk::Lambda::Function.new(self, "Function",
        code: { "ZipFile" => "xxx" },
        handler: "index.handler",
        runtime: "nodejs24.x")
      fn.grant_invoke(role)
    end

    template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Version" => "2012-10-17",
        "Statement" => [
          {
            "Action" => "lambda:InvokeFunction",
            "Effect" => "Allow",
            "Resource" => [
              { "Fn::Join" => [ "", [ { "Fn::GetAtt" => [ "FunctionResource", "Arn" ] }, ":*" ] ] },
              { "Fn::GetAtt" => [ "FunctionResource", "Arn" ] }
            ]
          }
        ]
      },
      "Roles" => [ { "Ref" => "RoleResource" } ]
    })
  end

  private

  # A directory for the handler's code, under the test's own.
  def handler_dir
    File.join(dir, "my-lambda-handler")
  end
end
