# frozen_string_literal: true

require "ruby-cdk"

module Lambda
  # One function whose code is a zipped directory, with the role that runs it
  # and the log group its logs land in.
  #
  # The resources are L1 resources, written with CloudFormation's own property
  # names, after the CDK's file-asset integ scenario (aws-cdk-lib,
  # aws-s3-assets/test/integ.assets.directory.lit.ts at a2c633f, Apache-2.0,
  # with aws-lambda/test/integ.assets.lit.ts, the function that consumes such
  # an asset): `Code.fromAsset` of a directory becomes here `asset.zip` of one.
  #
  # The function's name comes from `unique_name`, which is stable across
  # deploys and made of the stack's env, so the log group's name —
  # /aws/lambda/<function name> — is a literal and the two always agree.
  class Stack < RubyCdk::Stack
    def build
      role = resource("Role", "AWS::IAM::Role", properties: {
        "AssumeRolePolicyDocument" => {
          "Version" => "2012-10-17",
          "Statement" => [
            {
              "Effect" => "Allow",
              "Principal" => { "Service" => "lambda.amazonaws.com" },
              "Action" => "sts:AssumeRole"
            }
          ]
        },
        "ManagedPolicyArns" => [ "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" ]
      })

      log_group = resource("Logs", "AWS::Logs::LogGroup", properties: {
        "LogGroupName" => "/aws/lambda/#{function_name}",
        "RetentionInDays" => 7
      })

      function = resource("Function", "AWS::Lambda::Function", depends_on: [ log_group ], properties: {
        "Code" => asset.zip(__dir__.to_s, exclude: [ "stack.rb" ]).s3_location,
        "FunctionName" => function_name,
        "Handler" => "app.handler",
        "MemorySize" => 128,
        "Role" => Fn.get_att(role, "Arn"),
        "Runtime" => "ruby4.0",
        "Timeout" => 10
      })

      output("FunctionName", value: Fn.ref(function), description: "The name of the function")
      output("FunctionArn", value: Fn.get_att(function, "Arn"), description: "The ARN of the function")
    end

    private

    # "lambda-function-<8 hex>": the hash is made of the stack's account,
    # region and name, so the name is the same on every synth and every
    # deploy. Needs a concrete env, which this app pins in cdk.rb — an asset
    # needs one anyway, because the name of its bucket is made of the account
    # and the region.
    def function_name
      @function_name ||= unique_name("function")
    end
  end
end
