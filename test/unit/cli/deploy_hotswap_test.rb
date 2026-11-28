# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# `deploy --hotswap` and `--hotswap-fallback`, in process: the flags reach the
# engine, the pair is refused, the CDK's warning names itself once per command,
# and --json carries the hotswap facts. The engine behind it is the command
# line's fake client; the classification is held by the ported CDK cases
# (test/cdk/cli/hotswap_test.rb) and by the engine tests
# (test/unit/deploy/hotswap_test.rb).
class CliDeployHotswapTest < CliHelpers::TestCase
  FUNCTION_APP = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new do |app|
      RubyCdk::Stack.new(app, "hello") do
        resource("Func", "AWS::Lambda::Function", properties: {
          "Code" => { "S3Bucket" => "assets", "S3Key" => "new-key" },
          "FunctionName" => "my-function",
          "Handler" => "handler.run",
          "Runtime" => "ruby4.0",
          "Role" => "arn:aws:iam::111122223333:role/fn"
        })
      end
    end
  RUBY
  DEPLOYED = JSON.generate({ "AWSTemplateFormatVersion" => "2010-09-09", "Resources" => { "Func" => {
    "Type" => "AWS::Lambda::Function", "Properties" => {
    "Code" => { "S3Bucket" => "assets", "S3Key" => "old-key" }, "FunctionName" => "my-function",
    "Handler" => "handler.run", "Runtime" => "ruby4.0", "Role" => "arn:aws:iam::111122223333:role/fn" } } } })

  def given_deployed_function
    aws = CliHelpers::FakeAws.new
    aws.cfn.stack("hello", status: "UPDATE_COMPLETE", template: DEPLOYED)
    aws
  end

  # --- the flags reach the engine

  def test_hotswap_updates_the_stack_directly_and_skips_the_change_set
    write_app(FUNCTION_APP)
    aws = given_deployed_function

    result = cli("deploy", "--hotswap", *unattended, aws:)

    assert_equal 0, result.code
    assert_equal 1, aws.cfn.calls_to(:update_stack).size
    assert_empty aws.cfn.calls_to(:create_change_set), "no change set: the fast path skips it"
    assert_includes result.err.string, "✨ AWS::Lambda::Function 'my-function' hotswapped!"
  end

  def test_hotswap_fallback_hands_the_deploy_to_the_change_set_when_nothing_is_hotswappable
    write_app(<<~RUBY)
      require "ruby-cdk"
      RubyCdk::App.new do |app|
        RubyCdk::Stack.new(app, "hello") { resource("Bucket", "AWS::S3::Bucket", properties: { "BucketName" => "renamed" }) }
      end
    RUBY
    aws = CliHelpers::FakeAws.new
    aws.cfn.stack("hello", status: "UPDATE_COMPLETE", template: JSON.generate({ "AWSTemplateFormatVersion" => "2010-09-09", "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" } } }))

    result = cli("deploy", "--hotswap-fallback", *unattended, aws:)

    assert_equal 0, result.code
    assert_empty aws.cfn.calls_to(:update_stack)
    assert_equal 1, aws.cfn.calls_to(:create_change_set).size
    assert_equal 1, aws.cfn.calls_to(:execute_change_set).size
    assert_includes result.err.string, "Falling back to doing a full deployment"
  end

  # --- the pair is refused, as the CDK refuses it

  def test_both_flags_are_a_usage_error_before_any_client_is_built
    write_app(FUNCTION_APP)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", "--hotswap", "--hotswap-fallback", *unattended, aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "Can not supply both --hotswap and --hotswap-fallback at the same time"
    assert_includes result.err.string, "Run `ruby-cdk deploy` again with only one of the two flags."
    assert_empty aws.client_calls
  end

  # --- the warning above every hotswap deploy, once per command

  def test_the_cdk_s_warning_is_printed_once_per_command
    write_app(FUNCTION_APP)
    aws = given_deployed_function

    result = cli("deploy", "--hotswap", *unattended, aws:)

    assert_equal 0, result.code
    assert_includes result.err.string,
      "⚠️ The --hotswap and --hotswap-fallback flags deliberately introduce CloudFormation drift to speed up deployments"
    assert_includes result.err.string, "⚠️ They should only be used for development - never use them for your production Stacks!"
    assert_equal 1, result.err.string.scan("deliberately introduce CloudFormation drift").size, "once per command, not per stack"
  end

  def test_without_the_flags_there_is_no_warning
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", *unattended, aws:)

    assert_equal 0, result.code
    refute_includes result.err.string, "deliberately introduce CloudFormation drift"
  end

  # --- --json: the hotswap facts

  def test_json_carries_the_hotswap_facts_of_the_fast_path
    write_app(FUNCTION_APP)
    aws = given_deployed_function

    result = cli("deploy", "--hotswap", "--json", *unattended, aws:)

    assert_equal 0, result.code
    record = result.records.first
    assert_equal %w[name stack_id outcome exit_code changes outputs hotswap], record.keys
    facts = record["hotswap"]
    assert_equal "hotswap-only", facts["mode"]
    assert_equal false, facts["fell_back"]
    assert_equal [ { "logical_id" => "Func", "resource_type" => "AWS::Lambda::Function", "name" => "my-function" } ],
      facts["swapped"]
    assert_empty facts["non_hotswappable"]
  end

  def test_json_carries_what_fell_back_and_why
    write_app(<<~RUBY)
      require "ruby-cdk"
      RubyCdk::App.new do |app|
        RubyCdk::Stack.new(app, "hello") { resource("Bucket", "AWS::S3::Bucket", properties: { "BucketName" => "renamed" }) }
      end
    RUBY
    aws = CliHelpers::FakeAws.new
    aws.cfn.stack("hello", status: "UPDATE_COMPLETE", template: JSON.generate({ "AWSTemplateFormatVersion" => "2010-09-09", "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" } } }))

    result = cli("deploy", "--hotswap-fallback", "--json", *unattended, aws:)

    assert_equal 0, result.code
    facts = result.records.first["hotswap"]
    assert_equal "fall-back", facts["mode"]
    assert facts["fell_back"]
    assert_empty facts["swapped"]
    assert_equal [ "AWS::S3::Bucket" ], facts["non_hotswappable"].map { |change| change["resource_type"] }
    assert_includes facts["non_hotswappable"].first["reason"], "not supported for hotswap deployments"
  end

  def test_a_deploy_without_the_flags_has_no_hotswap_key
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", "--json", *unattended, aws:)

    assert_equal 0, result.code
    assert_nil result.records.first["hotswap"]
  end
end
