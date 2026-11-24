# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# `deploy`, in process: the command line over the whole engine, with the
# engine's own fake client behind the command line's client factory. No client
# is built and nothing reaches AWS.
class CliDeployTest < CliHelpers::TestCase
  # network is deployed first, then web and db, which depend on it.
  NETWORK_THEN_WEB = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new do |app|
      network = RubyCdk::Stack.new(app, "network") do
        resource("Vpc", "AWS::EC2::VPC", properties: { "CidrBlock" => "10.0.0.0/16" })
      end
      RubyCdk::Stack.new(app, "web") { resource("Queue", "AWS::SQS::Queue") }.add_dependency(network)
      RubyCdk::Stack.new(app, "db") do
        resource("Table", "AWS::DynamoDB::Table", properties: {
          "AttributeDefinitions" => [ { "AttributeName" => "id", "AttributeType" => "S" } ],
          "KeySchema" => [ { "AttributeName" => "id", "KeyType" => "HASH" } ]
        })
      end.add_dependency(network)
    end
  RUBY
  CIRCLE = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new do |app|
      network = RubyCdk::Stack.new(app, "network") { resource("Vpc", "AWS::EC2::VPC", properties: { "CidrBlock" => "10.0.0.0/16" }) }
      web = RubyCdk::Stack.new(app, "web") { resource("Queue", "AWS::SQS::Queue") }
      web.add_dependency(network)
      network.add_dependency(web)
    end
  RUBY

  # A fake whose CloudFormation refuses the change set of one stack. The whole
  # signature is spelled out on purpose: on this Ruby, a bare `*` rest folds
  # the original call's keywords into the array, and a bare `super` would pass
  # them on as positionals, which the engine's fake refuses by arity.
  class WebIsRejected < RubyCdk::Deploy::Fakes::CfnClient
    def create_change_set(name, change_set_name, template:, change_set_type:, parameters:, tags:, capabilities:, on_stack_failure: nil)
      raise RubyCdk::ChangeSetRejected, "ValidationError: web is not allowed here" if name == "web"

      super
    end
  end

  def created(aws)
    aws.cfn.calls_to(:create_change_set).map { |call| call.args.first }
  end

  # The stack's outputs once it exists: the reads of the stack answer with
  # them. The ID is read from the fake's record at call time, because the stack
  # is created by the deploy itself.
  def with_outputs(aws, outputs)
    reads = 0
    aws.cfn.on(:stack_info, lambda do |call|
      reads += 1
      id = aws.cfn.stack_record(call.args.first)&.id || call.args.first
      if reads == 1
        RubyCdk::Deploy::StackInfo.new(name: "hello", id:, status: "REVIEW_IN_PROGRESS", outputs: {}, termination_protection: false)
      else
        RubyCdk::Deploy::StackInfo.new(name: "hello", id:, status: "CREATE_COMPLETE", outputs:, termination_protection: false)
      end
    end)
    aws
  end

  # --- the flow, and the exit codes of architecture section 14

  def test_deploy_creates_the_stack_with_the_synthesized_template_and_executes_the_change_set
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", *unattended, aws:)

    assert_equal 0, result.code
    call = aws.cfn.calls_to(:create_change_set).first
    assert_equal "hello", call.args.first
    assert_equal File.binread(File.join(dir, "cdk.out", "hello.template.json")), call.kwargs[:template]
    assert_equal :create, call.kwargs[:change_set_type]
    assert_equal "DELETE", call.kwargs[:on_stack_failure], "a first deploy that fails deletes its stack"
    assert_equal 1, aws.cfn.calls_to(:execute_change_set).size
    assert aws.cfn.calls_to(:execute_change_set).first.kwargs[:retain_except_on_create]
    assert_equal "CREATE_COMPLETE", aws.cfn.stack_record("hello").status
    assert_includes result.err.string, "Target: account #{CliHelpers::ACCOUNT}, region #{CliHelpers::REGION}, " \
      "profile the default credential chain\n"
    assert_equal "", result.out.string, "no outputs yet: nothing on standard out"
  end

  def test_the_outputs_are_printed_and_written_to_the_outputs_file
    write_app(ONE_STACK)
    FileUtils.mkdir_p(File.join(dir, "out"))
    aws = with_outputs(CliHelpers::FakeAws.new, { "QueueName" => "https://sqs.eu-west-1.amazonaws.com/#{CliHelpers::ACCOUNT}/hello" })

    result = cli("deploy", *unattended, "--outputs-file", "out/outputs.json", aws:)

    assert_equal 0, result.code
    assert_equal "Outputs:\n  QueueName = https://sqs.eu-west-1.amazonaws.com/#{CliHelpers::ACCOUNT}/hello\n", result.out.string
    # The file carries one entry per stack, as the CDK accumulates it
    # (cdk-toolkit.ts:2696): another stack's entry survives this deploy's.
    assert_equal({ "hello" => { "QueueName" => "https://sqs.eu-west-1.amazonaws.com/#{CliHelpers::ACCOUNT}/hello" } },
      JSON.parse(File.read(File.join(dir, "out", "outputs.json"))))
  end

  def test_without_yes_and_without_a_terminal_the_approval_is_not_given_exit_4
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", aws:)

    assert_equal 4, result.code
    assert_includes result.err.string, "No terminal is attached to answer the question, so the command stopped, and nothing was deployed."
    assert_includes result.err.string, "Run `ruby-cdk deploy` again with --yes to do it without the question, " \
      "or run it in a terminal to answer it.\n"
    assert_equal "DELETE_COMPLETE", aws.cfn.stack_record("hello").status, "the refused creation is deleted"
  end

  def test_an_unattended_deploy_of_a_stack_without_env_needs_the_account_exit_1
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", "--yes", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "An unattended deploy (--yes) of stack hello, which has no env, needs --account"
    assert_empty created(aws), "nothing is asked of CloudFormation"
  end

  def test_the_account_given_must_be_the_credentials_account_exit_1
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", "--yes", "--account", "999988887777", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "--account 999988887777 was given, but the credentials are for account #{CliHelpers::ACCOUNT}"
    assert_empty created(aws)
  end

  def test_a_change_set_cloudformation_rejects_is_exit_3
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new
    aws.cfn.on(:create_change_set, RubyCdk::ChangeSetRejected.new("InsufficientCapabilitiesException: Requires capabilities : [CAPABILITY_IAM]"))

    result = cli("deploy", *unattended, aws:)

    assert_equal 3, result.code
    assert_includes result.err.string, "InsufficientCapabilitiesException: Requires capabilities"
  end

  def test_a_stack_operation_that_fails_is_exit_5
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new
    aws.cfn.execute_result("ROLLBACK_COMPLETE")

    result = cli("deploy", *unattended, aws:)

    assert_equal 5, result.code
    assert_includes result.err.string, "Stack hello ended in ROLLBACK_COMPLETE"
  end

  def test_no_execute_leaves_the_change_set_unexecuted
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", "--yes", "--account", CliHelpers::ACCOUNT, "--no-execute", aws:)

    assert_equal 0, result.code
    assert_equal 1, created(aws).size
    assert_empty aws.cfn.calls_to(:execute_change_set)
    assert_includes result.err.string, "--no-execute"
  end

  def test_quiet_prints_no_progress_but_still_the_target
    write_app(ONE_STACK)
    human = cli("deploy", *unattended, aws: CliHelpers::FakeAws.new)
    quiet = cli("deploy", *unattended, "--quiet", aws: CliHelpers::FakeAws.new)

    assert_equal 0, human.code
    assert_includes human.err.string, "Changes\n"
    assert_equal 0, quiet.code
    refute_includes quiet.err.string, "Changes"
    assert_includes quiet.err.string, "Target: account #{CliHelpers::ACCOUNT}"
  end

  # --- --json: one object per stack on standard out, and nothing else there

  def test_json_is_one_object_per_stack_on_standard_out_and_nothing_else
    write_app(ONE_STACK)
    aws = with_outputs(CliHelpers::FakeAws.new, { "QueueName" => "hello-queue" })

    result = cli("deploy", *unattended, "--json", aws:)

    assert_equal 0, result.code
    assert_equal 1, result.out.string.lines.size
    record = result.records.first
    assert_equal %w[name stack_id outcome exit_code changes outputs], record.keys
    assert_equal "hello", record["name"]
    assert_match(/stack\/hello\//, record["stack_id"])
    assert_equal "deployed", record["outcome"]
    assert_equal 0, record["exit_code"]
    assert_equal [ "Add" ], record["changes"].map { |change| change["action"] }
    assert_equal({ "QueueName" => "hello-queue" }, record["outputs"])
    assert result.err.string.lines.all? { |line| JSON.parse(line) }, "the engine's words are JSON lines on standard error"
  end

  def test_json_names_the_exit_code_and_the_error_of_a_stack_that_failed
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new
    aws.cfn.execute_result("ROLLBACK_COMPLETE")

    failed = cli("deploy", *unattended, "--json", aws:).records.first
    assert_equal "failed", failed["outcome"]
    assert_equal 5, failed["exit_code"]

    aws = CliHelpers::FakeAws.new
    aws.cfn.on(:create_change_set, RubyCdk::ChangeSetRejected.new("ValidationError: nothing to do"))
    rejected = cli("deploy", *unattended, "--json", aws:).records.first
    assert_equal %w[name stack_id outcome exit_code changes outputs error], rejected.keys
    assert_nil rejected["outcome"]
    assert_equal 3, rejected["exit_code"]
    assert_includes rejected["error"], "ValidationError: nothing to do"
  end

  # --- which stacks: the CDK's rules

  def test_no_name_in_an_app_of_several_stacks_is_a_usage_error_before_any_client
    write_app(NETWORK_THEN_WEB)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", *unattended, aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "Since this app includes more than a single stack, specify which stacks to use or specify `--all`\n" \
      "Stacks: network · web · db\n"
    assert result.err.string.end_with?("Run `ruby-cdk deploy --all`, or `ruby-cdk deploy STACK` for one of them.\n")
    assert_empty aws.client_calls
  end

  def test_all_deploys_every_stack_dependencies_first
    write_app(NETWORK_THEN_WEB)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", "--all", *unattended, aws:)

    assert_equal 0, result.code
    assert_equal %w[network web db], created(aws)
  end

  def test_a_named_stack_brings_what_it_depends_on_unless_exclusively
    write_app(NETWORK_THEN_WEB)
    with_dependencies = CliHelpers::FakeAws.new
    alone = CliHelpers::FakeAws.new

    assert_equal 0, cli("deploy", "db", *unattended, aws: with_dependencies).code
    assert_equal %w[network db], created(with_dependencies)

    assert_equal 0, cli("deploy", "db", "--exclusively", *unattended, aws: alone).code
    assert_equal %w[db], created(alone)
  end

  def test_the_first_failure_stops_the_deploy_and_json_says_which_stacks_were_not_attempted
    write_app(NETWORK_THEN_WEB)
    aws = CliHelpers::FakeAws.new(cfn: WebIsRejected.new)

    result = cli("deploy", "--all", *unattended, "--json", aws:)

    assert_equal 3, result.code
    # web was asked for and refused before the fake's log records a call, so
    # its ask is proven by its record below, and db was never asked for.
    assert_equal %w[network], created(aws)
    records = result.records
    assert_equal %w[network web db], records.map { |record| record["name"] }
    assert_equal "deployed", records[0]["outcome"]
    assert_equal 3, records[1]["exit_code"]
    assert_includes records[1]["error"], "web is not allowed here"
    assert_nil records[2]["exit_code"]
    assert_equal "not attempted: web before it ended with exit code 3", records[2]["error"]
  end

  def test_names_are_checked_before_any_client_is_built
    write_app(NETWORK_THEN_WEB)
    typo = CliHelpers::FakeAws.new
    both = CliHelpers::FakeAws.new

    result = cli("deploy", "typo", *unattended, aws: typo)

    assert_equal 1, result.code
    assert_includes result.err.string, "ruby-cdk: No stacks match the name(s) typo\n"
    assert_empty typo.client_calls

    result = cli("deploy", "--all", "web", *unattended, aws: both)

    assert_equal 1, result.code
    assert_includes result.err.string, "You must either specify a list of Stacks or the `--all` argument"
    assert_empty both.client_calls
  end

  def test_a_circle_of_dependencies_is_refused_when_the_app_file_builds
    # The tree refuses a cycle as it is built (Stack#add_dependency), so the
    # command never sees one: the error is reported at the app file's line.
    write_app(CIRCLE)
    aws = CliHelpers::FakeAws.new

    result = cli("deploy", "--all", *unattended, aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "depending on web makes a cyclic reference: web already depends on network"
    assert_match(%r{cdk\.rb: line 6, in }, result.err.string)
    assert_empty aws.client_calls
  end
end
