# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# `bootstrap`: the command over the bootstrap component, against the engine's
# own fakes behind the command line's client factory. The component's tests
# (test/unit/bootstrap) pin the stack and the pre-flight; these pin the
# command: no app file, the resolved target, --deployer, the exit codes.
class CliBootstrapTest < CliHelpers::TestCase
  ACCOUNT = CliHelpers::ACCOUNT
  REGION = CliHelpers::REGION
  BUCKET = "ruby-cdk-assets-#{ACCOUNT}-#{REGION}"
  STACK_NAME = "ruby-cdk-bootstrap"

  # --- the flow

  def test_bootstrap_deploys_without_an_app_file
    # No cdk.rb is written: bootstrap builds the App itself.
    aws = CliHelpers::FakeAws.new

    result = cli("bootstrap", "--yes", aws:)

    assert_equal 0, result.code
    change_set = aws.cfn.change_sets.values.first
    assert_equal STACK_NAME, aws.cfn.calls_to(:create_change_set).first.args.first
    assert_equal :create, change_set.type
    assert_equal "DELETE", change_set.on_stack_failure
    assert_equal [ { key: "ruby-cdk", value: RubyCdk::VERSION } ], change_set.tags
    assert_includes result.err.string, "Target: account #{ACCOUNT}, region #{REGION}"
    assert_equal "", result.out.string
  end

  def test_the_region_is_the_option_or_what_the_adapters_resolve
    # A client built for us-east-1 answers an identity there, as the adapter
    # does; the default fake's identity sits in eu-west-1.
    elsewhere = RubyCdk::Deploy::Identity.new(account: ACCOUNT, region: "us-east-1", arn: "arn:aws:iam::#{ACCOUNT}:user/deployer")
    written = CliHelpers::FakeAws.new(region: "us-east-1", cfn: RubyCdk::Deploy::Fakes::CfnClient.new(identity: elsewhere))
    resolved = CliHelpers::FakeAws.new

    assert_equal 0, cli("bootstrap", "--yes", "--region", "us-east-1", aws: written).code
    assert_empty written.region_calls, "--region names the region: nothing is resolved"
    assert_equal [ [ nil, "us-east-1" ] ], written.client_calls

    assert_equal 0, cli("bootstrap", "--yes", aws: resolved).code
    assert_equal [ [ nil, nil ] ], resolved.region_calls
    assert_equal [ [ nil, REGION ] ], resolved.client_calls
  end

  def test_when_nothing_names_a_region_no_client_is_built
    aws = CliHelpers::FakeAws.new.fail_region_with(RubyCdk::PreconditionError.new("No region: pass --region"))

    result = cli("bootstrap", "--yes", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "No region: pass --region"
    assert_empty aws.client_calls
  end

  # --- --deployer

  def test_the_deployer_arn_reaches_the_bucket_policy
    aws = CliHelpers::FakeAws.new

    assert_equal 0, cli("bootstrap", "--yes", "--deployer", "arn:aws:iam::#{ACCOUNT}:role/deployer", aws:).code

    template = JSON.parse(aws.cfn.change_sets.values.first.template)
    policy = template.fetch("Resources").fetch("BucketPolicy").fetch("Properties").fetch("PolicyDocument")
    statement = policy.fetch("Statement").find { |one| one.fetch("Sid") == "DeployerReadsAssets" }
    assert_equal "arn:aws:iam::#{ACCOUNT}:role/deployer", statement.dig("Principal", "AWS")
  end

  def test_without_a_deployer_the_account_root_is_granted
    aws = CliHelpers::FakeAws.new

    assert_equal 0, cli("bootstrap", "--yes", aws:).code

    template = JSON.parse(aws.cfn.change_sets.values.first.template)
    policy = template.fetch("Resources").fetch("BucketPolicy").fetch("Properties").fetch("PolicyDocument")
    statement = policy.fetch("Statement").find { |one| one.fetch("Sid") == "DeployerReadsAssets" }
    assert_equal "arn:aws:iam::#{ACCOUNT}:root", statement.dig("Principal", "AWS")
  end

  # --- the guard: --account is an assertion

  def test_an_account_that_is_not_the_credentials_account_is_refused_before_anything_is_built
    aws = CliHelpers::FakeAws.new

    result = cli("bootstrap", "--yes", "--account", "999988887777", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "--account 999988887777 was given, but the credentials are for account #{ACCOUNT}"
    assert_includes result.err.string, "Nothing was created."
    assert_empty aws.cfn.calls_to(:create_change_set)
  end

  # --- the pre-flight, through the component

  def test_an_orphan_bucket_stops_bootstrap_with_the_two_ways_out_exit_1
    store = AssetsFakeObjectStore.new(owner: ACCOUNT)
    store.add_bucket(BUCKET, owner: ACCOUNT)
    aws = CliHelpers::FakeAws.new(store:)

    result = cli("bootstrap", "--yes", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "Two ways out"
    assert_empty aws.cfn.calls_to(:create_change_set), "nothing was created"
  end

  def test_a_foreign_bucket_stops_bootstrap_before_anything_is_created_exit_1
    store = AssetsFakeObjectStore.new(owner: ACCOUNT)
    store.add_bucket(BUCKET, owner: "999988887777")
    aws = CliHelpers::FakeAws.new(store:)

    result = cli("bootstrap", "--yes", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "it is not owned by account #{ACCOUNT}"
    assert_empty aws.cfn.calls_to(:create_change_set)
  end

  def test_the_missing_bucket_note_is_announced_before_the_deploy
    prepare_stable_bootstrap(aws = CliHelpers::FakeAws.new)

    result = cli("bootstrap", "--yes", aws:)

    assert_equal 0, result.code
    assert_includes result.err.string, "#{BUCKET} does not exist"
    assert_includes result.err.string, "does not recreate a bucket the template already names"
  end

  # --- approval, and the exit codes

  def test_without_yes_and_without_a_terminal_the_approval_is_not_given_exit_4
    aws = CliHelpers::FakeAws.new

    result = cli("bootstrap", aws:)

    assert_equal 4, result.code
    assert_includes result.err.string, "No terminal is attached to answer the question, so the command stopped, " \
      "and nothing was deployed."
  end

  def test_a_failed_bootstrap_maps_to_exit_5
    aws = CliHelpers::FakeAws.new
    aws.cfn.execute_result("ROLLBACK_COMPLETE")

    result = cli("bootstrap", "--yes", aws:)

    assert_equal 5, result.code
    assert_includes result.err.string, "ended in ROLLBACK_COMPLETE"
  end

  # --- --json

  def test_json_is_one_object_on_standard_out
    aws = CliHelpers::FakeAws.new

    result = cli("bootstrap", "--yes", "--json", aws:)

    assert_equal 0, result.code
    assert_equal 1, result.out.string.lines.size
    record = result.records.first
    assert_equal %w[name stack_id outcome exit_code changes outputs], record.keys
    assert_equal STACK_NAME, record.fetch("name")
    assert_equal "deployed", record.fetch("outcome")
    assert_equal 0, record.fetch("exit_code")
    assert_equal [ "Add" ], record.fetch("changes").map { |change| change["action"] }
    assert_empty record.fetch("outputs")
    assert result.err.string.lines.all? { |line| JSON.parse(line) }, "the engine's words are JSON lines on standard error"
  end

  private

  # The bootstrap stack as a stable CloudFormation stack, with its bucket gone:
  # the pre-flight answers :update with the announcement, and the engine skips
  # or updates from there.
  def prepare_stable_bootstrap(aws)
    template = JSON.generate(RubyCdk::Bootstrap.stack(app: RubyCdk::App.new(env: RubyCdk::Env.new(account: ACCOUNT, region: REGION))).to_template)
    aws.cfn.stack(STACK_NAME, template:, tags: [ { key: "ruby-cdk", value: RubyCdk::VERSION } ])
  end
end
