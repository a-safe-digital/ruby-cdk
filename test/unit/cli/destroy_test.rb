# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# `destroy`, in process: the command line over the whole engine, with the
# engine's own fake client behind the command line's client factory.
class CliDestroyTest < CliHelpers::TestCase
  NETWORK_THEN_WEB = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new do |app|
      network = RubyCdk::Stack.new(app, "network") { resource("Vpc", "AWS::EC2::VPC", properties: { "CidrBlock" => "10.0.0.0/16" }) }
      RubyCdk::Stack.new(app, "web") { resource("Queue", "AWS::SQS::Queue") }.add_dependency(network)
    end
  RUBY
  PLAIN_TEMPLATE = '{"Resources":{"Queue":{"Type":"AWS::SQS::Queue"}}}'
  KEEPING_TEMPLATE = '{"Resources":{"Table":{"Type":"AWS::DynamoDB::Table","DeletionPolicy":"Retain"}}}'

  # A fake with these stacks in CloudFormation, as a deploy left them. The
  # keywords are the fake client's own for `stack`.
  def existing(*names, template: PLAIN_TEMPLATE, **options)
    aws = CliHelpers::FakeAws.new
    names.each { |name| aws.cfn.stack(name, template:, **options) }
    aws
  end

  # The stacks in the order their deletion was asked for.
  def deleted(aws)
    aws.cfn.calls_to(:delete_stack).filter_map { |call| aws.cfn.stack_record(call.args.first)&.name }
  end

  def test_destroy_of_the_only_stack_deletes_it_by_its_id
    write_app(ONE_STACK)
    aws = existing("hello")
    id = aws.cfn.stack_record("hello").id

    result = cli("destroy", "--yes", aws:)

    assert_equal 0, result.code
    assert_equal [ "hello" ], deleted(aws)
    assert_equal [ id ], aws.cfn.calls_to(:delete_stack).map { |call| call.args.first }, "the ID, which still names the stack once deleted"
    assert_equal "DELETE_COMPLETE", aws.cfn.stack_record("hello").status
  end

  def test_a_stack_that_is_not_in_cloudformation_is_nothing_to_do
    write_app(ONE_STACK)
    aws = CliHelpers::FakeAws.new

    result = cli("destroy", "--yes", "--json", aws:)

    assert_equal 0, result.code
    assert_equal "no_changes", result.records.first["outcome"]
    assert_includes result.err.string, "Stack hello does not exist: nothing to destroy."
  end

  def test_no_name_in_an_app_of_several_stacks_is_a_usage_error_and_nothing_is_deleted
    write_app(NETWORK_THEN_WEB)
    aws = existing("network", "web")

    result = cli("destroy", "--yes", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "Since this app includes more than a single stack, specify which stacks to use or specify `--all`\n" \
      "Stacks: network · web\n"
    assert result.err.string.end_with?("Run `ruby-cdk destroy --all`, or `ruby-cdk destroy STACK` for one of them.\n")
    assert_empty aws.cfn.calls_to(:delete_stack)
  end

  def test_all_destroys_every_stack_the_depended_on_ones_last
    write_app(NETWORK_THEN_WEB)
    aws = existing("network", "web")

    assert_equal 0, cli("destroy", "--all", "--yes", aws:).code
    assert_equal %w[web network], deleted(aws)
  end

  def test_a_named_destroy_brings_what_depends_on_it_unless_exclusively
    write_app(NETWORK_THEN_WEB)

    with_dependents = existing("network", "web")
    assert_equal 0, cli("destroy", "network", "--yes", aws: with_dependents).code
    assert_equal %w[web network], deleted(with_dependents)

    alone = existing("network", "web")
    assert_equal 0, cli("destroy", "network", "--yes", "--exclusively", aws: alone).code
    assert_equal %w[network], deleted(alone)

    web_only = existing("network", "web")
    assert_equal 0, cli("destroy", "web", "--yes", aws: web_only).code
    assert_equal %w[web], deleted(web_only), "destroying a stack does not touch what it depends on"
  end

  def test_names_are_checked_before_any_client_is_built
    write_app(NETWORK_THEN_WEB)
    typo = existing("network", "web")
    both = existing("network", "web")

    result = cli("destroy", "typo", "--yes", aws: typo)

    assert_equal 1, result.code
    assert_includes result.err.string, "ruby-cdk: No stacks match the name(s) typo\n"
    assert_empty typo.client_calls

    result = cli("destroy", "--all", "web", "--yes", aws: both)

    assert_equal 1, result.code
    assert_includes result.err.string, "You must either specify a list of Stacks or the `--all` argument"
    assert_empty both.client_calls
  end

  def test_without_yes_and_without_a_terminal_the_name_is_not_typed_exit_4
    write_app(ONE_STACK)
    aws = existing("hello")

    result = cli("destroy", aws:)

    assert_equal 4, result.code
    assert_includes result.err.string, "No terminal is attached to answer the question, so the command stopped, and nothing was deleted."
    assert_includes result.err.string, "Run `ruby-cdk destroy` again with --yes to do it without the question, " \
      "or run it in a terminal to answer it.\n"
    assert_empty aws.cfn.calls_to(:delete_stack)
  end

  def test_force_skips_the_confirmation_as_in_the_cdk
    write_app(ONE_STACK)
    aws = existing("hello")

    assert_equal 0, cli("destroy", "--force", aws:).code
    assert_equal %w[hello], deleted(aws)
  end

  def test_what_the_stack_keeps_is_said_before_the_deletion
    write_app(ONE_STACK)
    aws = existing("hello", template: KEEPING_TEMPLATE)

    result = cli("destroy", "--yes", aws:)

    assert_equal 0, result.code
    assert_includes result.err.string, "Kept after the stack is deleted (their DeletionPolicy says so):\n  Table  AWS::DynamoDB::Table  Retain\n"
  end

  def test_a_stack_protected_from_deletion_is_refused_exit_1
    write_app(ONE_STACK)
    aws = existing("hello", termination_protection: true)

    result = cli("destroy", "--yes", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "Stack hello has termination protection, so destroy refuses to delete it"
    assert_empty aws.cfn.calls_to(:delete_stack)
  end

  def test_json_is_one_object_per_stack
    write_app(NETWORK_THEN_WEB)
    aws = existing("network", "web")

    result = cli("destroy", "--all", "--yes", "--json", aws:)

    assert_equal 0, result.code
    assert_equal %w[web network], result.records.map { |record| record["name"] }
    assert_equal %w[name stack_id outcome exit_code changes outputs], result.records.first.keys
    # The engine answers :deployed for a destroyed stack; the command line passes it on as it is.
    assert_equal %w[deployed deployed], result.records.map { |record| record["outcome"] }
    assert_equal [ 0, 0 ], result.records.map { |record| record["exit_code"] }
    assert_equal aws.cfn.stack_record("web").id, result.records.first["stack_id"]
  end

  def test_a_deletion_that_fails_is_exit_5
    write_app(ONE_STACK)
    aws = existing("hello", status: "DELETE_FAILED")
    # The deletion itself is scripted: first the state the destroy is asked
    # into, then the operation it starts, which ends still failed.
    aws.cfn.on(:stack_state, :stable, :busy, :rollback_failed)
    aws.cfn.on(:stack_info, RubyCdk::Deploy::StackInfo.new(name: "hello", id: aws.cfn.stack_record("hello").id,
      status: "DELETE_FAILED", outputs: {}, termination_protection: false))

    result = cli("destroy", "--yes", aws:)

    assert_equal 5, result.code
    assert_includes result.err.string, "Stack hello could not be deleted: it ended in DELETE_FAILED."
    assert_equal [ "hello" ], deleted(aws)
  end
end
