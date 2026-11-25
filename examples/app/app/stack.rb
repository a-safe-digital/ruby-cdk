# frozen_string_literal: true

require "ruby-cdk"

module Notes
  # A function, a table, a bucket and one least-privilege role for them all:
  # the curated constructs of Wave 7, after the CDK's own integ scenarios
  # aws-iam/test/integ.role.ts and aws-lambda/test/integ.lambda.ts (aws-cdk at
  # c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0). `Code.fromAsset`
  # of a directory becomes here `asset.zip` of one.
  #
  # The role is least-privilege in three lines: it is trusted by Lambda,
  # carries the basic execution policy that lets CloudWatch Logs keep the
  # function's logs, and is granted exactly the table's data read/write and
  # the bucket's read/write - nothing else, and nothing to anything else.
  #
  # The names come from `unique_name`, which is stable across deploys and made
  # of the stack's env, so the function's log group - /aws/lambda/<function
  # name>, which the function construct makes - agrees with the function on
  # every synth and every deploy.
  class Stack < RubyCdk::Stack
    def build
      role = RubyCdk::IAM::Role.new(self, "Role",
        assumed_by: "lambda.amazonaws.com",
        managed_policy_arns: [ RubyCdk::Lambda::Function::BASIC_EXECUTION_POLICY_ARN ],
        role_name: unique_name("notes-role", max_length: 64))

      table = RubyCdk::DynamoDB::Table.new(self, "Notes",
        partition_key: { name: "id", type: :string },
        table_name: unique_name("notes"))

      bucket = RubyCdk::S3::Bucket.new(self, "Assets", versioned: true)

      function = RubyCdk::Lambda::Function.new(self, "Fn",
        code: asset.zip(__dir__.to_s, exclude: [ "stack.rb" ]),
        handler: "app.handler",
        role: role,
        function_name: unique_name("notes-fn"))

      # The grants: the least-privilege part, three lines for the whole app.
      table.grant_read_write_data(role)
      bucket.grant_read_write(role)

      output("FunctionName", value: Fn.ref(function), description: "The name of the function")
      output("FunctionArn", value: Fn.get_att(function, "Arn"), description: "The ARN of the function")
      output("TableName", value: table.table_name, description: "The name of the notes table")
      output("BucketName", value: bucket.bucket_name, description: "The name of the assets bucket")
    end
  end
end
