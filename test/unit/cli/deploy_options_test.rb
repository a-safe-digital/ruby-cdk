# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# The options of `deploy`: what reaches the change set, what is refused before
# any client is built, the region of a stack, and the assets.
class CliDeployOptionsTest < CliHelpers::TestCase
  WITH_ENV = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new(env: RubyCdk::Env.new(account: "#{CliHelpers::ACCOUNT}", region: "#{CliHelpers::REGION}")) do |app|
      RubyCdk::Stack.new(app, "hello") { resource("Queue", "AWS::SQS::Queue") }
    end
  RUBY

  def first_change_set(aws)
    aws.cfn.calls_to(:create_change_set).first
  end

  def deployed(aws, *words)
    cli("deploy", *unattended, *words, aws:)
  end

  def an_asset_app
    files = File.join(dir, "function")
    FileUtils.mkdir_p(files)
    File.write(File.join(files, "handler.rb"), "def handler(event:) = event\n")
    write_app(<<~RUBY)
      require "ruby-cdk"
      RubyCdk::App.new(env: RubyCdk::Env.new(account: "#{CliHelpers::ACCOUNT}", region: "#{CliHelpers::REGION}")) do |app|
        RubyCdk::Stack.new(app, "web") do
          resource("Function", "AWS::Lambda::Function", properties: { "Code" => asset.zip(#{files.inspect}).s3_location })
        end
      end
    RUBY
    files
  end

  # --- what reaches the change set

  def test_parameters_and_tags_reach_the_change_set
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new

    assert_equal 0, deployed(aws, "--parameters", "DelaySeconds=10,VisibilityTimeout=30", "--tags", "team=platform,env=test").code

    assert_equal [ { parameter_key: "DelaySeconds", parameter_value: "10" }, { parameter_key: "VisibilityTimeout", parameter_value: "30" } ],
      first_change_set(aws).kwargs[:parameters]
    assert_equal [ { key: "team", value: "platform" }, { key: "env", value: "test" } ], first_change_set(aws).kwargs[:tags]
  end

  def test_on_failure_is_passed_in_either_case
    write_app(ONE_STACK)
    rollback = CliHelpers::FakeAws.new
    do_nothing = CliHelpers::FakeAws.new

    deployed(rollback, "--on-failure", "rollback")
    deployed(do_nothing, "--on-failure", "DO_NOTHING")

    assert_equal "ROLLBACK", first_change_set(rollback).kwargs[:on_stack_failure]
    assert_equal "DO_NOTHING", first_change_set(do_nothing).kwargs[:on_stack_failure]
  end

  # --- refused before any client is built

  def test_an_option_that_cannot_be_used_is_a_usage_error_before_any_client_is_built
    write_app(ONE_STACK)
    refused = {
      [ "--on-failure", "EXPLODE" ] => /--on-failure must be one of DELETE, ROLLBACK or DO_NOTHING, not "EXPLODE"/,
      [ "--parameters", "DelaySeconds" ] => /--parameters takes KEY=VALUE pairs separated by commas, and "DelaySeconds" is not one/,
      [ "--parameters", "A=1,A=2" ] => /--parameters names "A" twice/,
      [ "--tags", "team" ] => /--tags takes KEY=VALUE pairs/,
      [ "--outputs-file", "nowhere/outputs.json" ] => %r{The directory of --outputs-file does not exist: .*/nowhere},
      [ "--profile=" ] => /--profile must not be empty/,
      [ "--account=" ] => /--account must not be empty/,
      [ "--region=" ] => /--region must not be empty/
    }

    refused.each do |words, message|
      aws = CliHelpers::FakeAws.new
      result = deployed(aws, *words)

      assert_equal 1, result.code, words.join(" ")
      assert_match(message, result.err.string)
      assert_empty aws.client_calls, "#{words.join(" ")}: no client is built"
      assert_empty aws.cfn.calls, "#{words.join(" ")}: nothing is asked of CloudFormation"
    end
  end

  # --- the region of a stack (architecture section 13): --region, else the stack's env, else what is resolved

  def test_without_a_region_and_without_an_env_the_adapters_resolve_it_and_the_profile_is_passed
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new

    assert_equal 0, deployed(aws, "--profile", "sandbox").code

    assert_equal [ [ "sandbox", nil ] ], aws.region_calls
    assert_equal [ [ "sandbox", CliHelpers::REGION ] ], aws.client_calls
  end

  def test_region_names_the_region_and_nothing_is_resolved
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new(region: "us-east-1")

    assert_equal 0, deployed(aws, "--region", "us-east-1").code

    assert_empty aws.region_calls
    assert_equal [ [ nil, "us-east-1" ] ], aws.client_calls
  end

  def test_the_env_of_a_stack_names_the_region_when_no_option_does
    write_app(WITH_ENV)
    aws = CliHelpers::FakeAws.new(region: "us-east-1")

    assert_equal 0, deployed(aws).code

    assert_empty aws.region_calls, "the stack's env says where it deploys"
    assert_equal [ [ nil, CliHelpers::REGION ] ], aws.client_calls
  end

  def test_region_wins_over_the_env_and_the_engine_refuses_the_mismatch
    write_app(WITH_ENV)
    # A client whose credentials say us-east-1, as --region us-east-1 builds one.
    elsewhere = RubyCdk::Deploy::Identity.new(account: CliHelpers::ACCOUNT, region: "us-east-1", arn: "arn:aws:iam::#{CliHelpers::ACCOUNT}:user/deployer")
    aws = CliHelpers::FakeAws.new(cfn: RubyCdk::Deploy::Fakes::CfnClient.new(identity: elsewhere))

    result = deployed(aws, "--region", "us-east-1")

    assert_equal 1, result.code
    assert_includes result.err.string, "The client is for region us-east-1, but stack hello has env " \
      "#{CliHelpers::ACCOUNT}/#{CliHelpers::REGION}"
    assert_equal [ [ nil, "us-east-1" ] ], aws.client_calls
  end

  def test_when_nothing_names_a_region_no_client_is_built
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new.fail_region_with(RubyCdk::PreconditionError.new("No region: pass --region"))

    result = deployed(aws)

    assert_equal 1, result.code
    assert_includes result.err.string, "No region: pass --region"
    assert_empty aws.client_calls
  end

  def test_a_stack_whose_env_is_another_account_is_refused_before_any_request
    write_app(WITH_ENV)
    other = RubyCdk::Deploy::Identity.new(account: "999988887777", region: CliHelpers::REGION, arn: "arn:aws:iam::999988887777:user/deployer")
    aws = CliHelpers::FakeAws.new(cfn: RubyCdk::Deploy::Fakes::CfnClient.new(identity: other))

    # --yes alone: --account would fail on its own, before the stack's env is read.
    result = cli("deploy", "--yes", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "The credentials are for account 999988887777, but stack hello has env " \
      "#{CliHelpers::ACCOUNT}/#{CliHelpers::REGION}"
    assert_empty aws.cfn.calls_to(:create_change_set)
  end

  # --- the assets: in their bucket before any change set (architecture section 8)

  def test_the_assets_of_a_stack_are_in_their_bucket_before_any_change_set
    files = an_asset_app
    bucket = RubyCdk::Assets.bucket_name(CliHelpers::ACCOUNT, CliHelpers::REGION)
    store = AssetsFakeObjectStore.new(owner: CliHelpers::ACCOUNT).add_bucket(bucket)
    aws = CliHelpers::FakeAws.new(store:)

    result = cli("deploy", "--yes", aws:)

    assert_equal 0, result.code
    put = store.calls_to(:put).first
    assert_equal bucket, put.bucket
    assert_equal "#{RubyCdk::Assets::Hasher.asset_hash(files)}.zip", put.key
    assert_equal CliHelpers::ACCOUNT, put.expected_owner
    assert_equal 1, aws.cfn.calls_to(:create_change_set).size
  end

  def test_a_bucket_that_is_not_ours_stops_the_deploy_before_any_change_set
    an_asset_app
    bucket = RubyCdk::Assets.bucket_name(CliHelpers::ACCOUNT, CliHelpers::REGION)
    store = AssetsFakeObjectStore.new(owner: CliHelpers::ACCOUNT).add_bucket(bucket, owner: "999988887777")
    aws = CliHelpers::FakeAws.new(store:)

    result = cli("deploy", "--yes", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "Bucket named '#{bucket}' exists, but we don't have access to it as account #{CliHelpers::ACCOUNT}"
    assert_empty aws.cfn.calls_to(:create_change_set)
    assert_empty store.calls_to(:put)
  end

  def test_a_bucket_that_does_not_exist_names_bootstrap
    an_asset_app
    aws = CliHelpers::FakeAws.new(store: AssetsFakeObjectStore.new(owner: CliHelpers::ACCOUNT))

    result = cli("deploy", "--yes", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "Run `ruby-cdk bootstrap` first."
    assert_empty aws.cfn.calls_to(:create_change_set)
  end

  def test_a_stack_without_an_asset_uploads_nothing_and_checks_nothing
    write_app(WITH_ENV)
    aws = CliHelpers::FakeAws.new

    assert_equal 0, cli("deploy", "--yes", aws:).code
    assert_empty aws.store.calls, "an account that was never bootstrapped deploys a stack without assets"
  end
end
