# frozen_string_literal: true

# The harness's logic, with a fake port and no client: WF-5's decisions, and
# the bookkeeping that lets a run claim it left nothing behind. The run against
# AWS itself is under test/integration/aws/ and only `rake integration` runs it.

require "test_helper"
require_relative "../../integration/guard"
require_relative "../../integration/runner"

# A CloudFormation port that records what it was asked, for the assertions.
class GuardFakeClient
  attr_reader :calls

  def initialize(identity)
    @identity = identity
    @calls = []
  end

  def resolve_identity
    @calls << :resolve_identity
    @identity
  end
end

class IntegrationGuardTest < Minitest::Test
  IDENTITY = RubyCdk::Deploy::Identity.new(account: "111122223333", region: "eu-central-1", arn: "arn:aws:iam::111122223333:user/deployer")

  def guard(variables, client = GuardFakeClient.new(IDENTITY))
    Integration::Guard.new(port: client, variables:)
  end

  def refused(variables, client = GuardFakeClient.new(IDENTITY))
    assert_raises(Integration::Guard::Refused) { guard(variables, client) }
  end

  def complete(account: "111122223333", region: "eu-central-1", profile: "monitoring")
    { "RUBY_CDK_AWS_PROFILE" => profile, "RUBY_CDK_ALLOW_ACCOUNT" => account, "RUBY_CDK_ALLOW_REGION" => region }
  end

  def test_a_missing_variable_refuses_before_any_request
    %w[RUBY_CDK_AWS_PROFILE RUBY_CDK_ALLOW_ACCOUNT RUBY_CDK_ALLOW_REGION].each do |missing|
      client = GuardFakeClient.new(IDENTITY)
      variables = complete.merge(missing => "")

      refused(variables, client)

        assert_empty client.calls, "#{missing}: nothing is asked of AWS"

        # A blank variable is as good as a missing one.
        refused(complete.merge(missing => "  "))
      end
  end

  def test_the_refusal_for_a_missing_variable_names_it_and_the_three
    variables = complete.tap { |all| all.delete("RUBY_CDK_ALLOW_REGION") }
    error = nil
    begin
      guard(variables)
    rescue Integration::Guard::Refused => e
      error = e
    end

    assert_includes error.message, "RUBY_CDK_ALLOW_REGION"
    assert_includes error.message, "never enter the repository"
    assert_match(/rake integration/, error.message)
  end

  def test_an_account_that_is_not_the_allowlisted_one_refuses_before_any_request
    client = GuardFakeClient.new(IDENTITY)

    error = begin
      guard(complete(account: "999988887777"), client)
      nil
    rescue Integration::Guard::Refused => e
      e
    end

    assert error, "the run is refused"
    assert_includes error.message, "are for account 111122223333"
    assert_includes error.message, "RUBY_CDK_ALLOW_ACCOUNT names 999988887777"
    assert_includes error.message, "before anything is created"
    assert_equal [ :resolve_identity ], client.calls
  end

  def test_a_region_that_is_not_the_allowlisted_one_refuses_before_any_request
    client = GuardFakeClient.new(RubyCdk::Deploy::Identity.new(account: "111122223333", region: "us-east-1", arn: "arn"))

    error = begin
      guard(complete, client)
      nil
    rescue Integration::Guard::Refused => e
      e
    end

    assert error, "the run is refused"
    assert_includes error.message, "is for region us-east-1"
    assert_includes error.message, "RUBY_CDK_ALLOW_REGION names eu-central-1"
    assert_equal [ :resolve_identity ], client.calls
  end

  def test_the_variables_that_agree_with_the_identity_let_the_run_in
    client = GuardFakeClient.new(IDENTITY)
    guard = guard(complete, client)

    assert_equal "111122223333", guard.allow_account
    assert_equal "eu-central-1", guard.allow_region
    assert_equal "monitoring", guard.profile
    assert_same IDENTITY, guard.identity
    assert_equal RubyCdk::Env.new(account: "111122223333", region: "eu-central-1"), guard.env
    assert_match(/account 111122223333, region eu-central-1, profile monitoring/, guard.to_s)
  end

  def test_the_env_carries_the_allowlist
    guard = guard(complete, GuardFakeClient.new(IDENTITY))

    assert_equal RubyCdk::Env.new(account: "111122223333", region: "eu-central-1"), guard.env
  end
end

# A CloudFormation port with stacks in it, for the runner's bookkeeping.
class RunnerFakeClient
  Stack = Data.define(:name, :id, :status)
  Resource = Data.define(:logical_id, :physical_id, :status)

  attr_reader :calls

  def initialize
    @stacks = {}
    @prefix = []
    @foreign = []
    @resources = {}
    @calls = []
  end

  def stack(name, id: "arn:aws:cloudformation:eu-central-1:111122223333:stack/#{name}/id-1")
    @stacks[name] = Stack.new(name:, id:, status: "CREATE_COMPLETE")
    self
  end

  def with_prefix(stacks)
    @prefix = stacks
    self
  end

  def with_foreign(stacks)
    @foreign = stacks
    self
  end

  def with_resources(id, resources)
    @resources[id] = resources
    self
  end

  def resolve_identity = IDENTITY

  def stack_info(name)
    @calls << [ :stack_info, name ]
    @stacks[name]
  end

  def delete_stack(id)
    @calls << [ :delete_stack, id ]
  end

  # Every stack that is not deleted, with name, id and status: the port lists
  # them all, and the prefix is the runner's to apply.
  def list_stacks
    @calls << [ :list_stacks ]
    @prefix + @foreign
  end

  def list_resources(id)
    @calls << [ :list_resources, id ]
    @resources.fetch(id, [])
  end
end

class IntegrationRunnerTest < Minitest::Test
  LOG = StringIO.new

  def runner(client)
    Integration::Runner.new(client:, log: LOG)
  end

  def test_app_options_carry_the_prefix_the_delete_default_and_the_env
    options = runner(RunnerFakeClient.new).app_options(RubyCdk::Env.new(account: "111122223333", region: "eu-central-1"))

    assert_equal "ruby-cdk-it-", options.fetch(:stack_name_prefix)
    assert_equal :delete, options.fetch(:stateful_default)
    assert_equal "111122223333", options.fetch(:env).account
  end

  def test_a_stack_is_deleted_by_its_id_which_is_recorded_first
    client = RunnerFakeClient.new.stack("web", id: "arn:aws:cloudformation:eu-central-1:111122223333:stack/web/id-7")
    helper = runner(client)

    helper.destroy("web")

    assert_equal({ "web" => "arn:aws:cloudformation:eu-central-1:111122223333:stack/web/id-7" }, helper.destroyed)
    assert_equal [ [ :stack_info, "web" ], [ :delete_stack, "arn:aws:cloudformation:eu-central-1:111122223333:stack/web/id-7" ] ],
      client.calls, "the ID is read before the deletion, and the deletion is of the ID"
  end

  def test_a_stack_cloudformation_does_not_have_is_left_alone
    client = RunnerFakeClient.new
    helper = runner(client)

    assert_nil helper.destroy("never-deployed")
    assert_empty helper.destroyed
    assert_equal [ [ :stack_info, "never-deployed" ] ], client.calls
  end

  def test_a_stack_left_behind_fails_the_audit_and_names_it
    client = RunnerFakeClient.new.with_prefix([ RunnerFakeClient::Stack.new(name: "ruby-cdk-it-hello", id: "arn:1", status: "CREATE_COMPLETE") ])
      .with_foreign([ RunnerFakeClient::Stack.new(name: "ruby-cdk-bootstrap", id: "arn:9", status: "CREATE_COMPLETE") ])
    helper = runner(client)
    helper.destroyed["hello"] = "arn:2"

    error = assert_raises(RubyCdk::PreconditionError) { helper.audit }

    assert_includes error.message, "ruby-cdk-it-hello"
    refute_includes error.message, "ruby-cdk-bootstrap", "a stack without the prefix is never this run's leftover"
    assert_includes error.message, "Delete what is left"
  end

  def test_an_empty_listing_passes_the_leftover_check
    client = RunnerFakeClient.new.with_prefix([])
    helper = runner(client)
    helper.destroyed["hello"] = "arn:1"
    client.with_resources("arn:1", [ RunnerFakeClient::Resource.new(logical_id: "Queue", physical_id: "https://queue", status: "DELETE_COMPLETE") ])

    assert helper.audit
  end

  def test_a_resource_cloudformation_skipped_is_reported_by_its_physical_id
    client = RunnerFakeClient.new.with_prefix([])
    client.with_resources("arn:1", [
      RunnerFakeClient::Resource.new(logical_id: "Table", physical_id: "arn:aws:dynamodb:eu-central-1:111122223333:table/kept", status: "DELETE_SKIPPED"),
      RunnerFakeClient::Resource.new(logical_id: "Queue", physical_id: "https://queue", status: "DELETE_COMPLETE")
    ])
    helper = runner(client)
    helper.destroyed["hello"] = "arn:1"

    error = assert_raises(RubyCdk::PreconditionError) { helper.audit }

    assert_includes error.message, "Table (arn:aws:dynamodb:eu-central-1:111122223333:table/kept)"
    assert_includes error.message, "A resource is skipped when its DeletionPolicy keeps it"
    assert_includes error.message, "Nothing here deletes a physical resource by hand"
    refute_includes error.message, "Queue (https://queue)", "a deleted resource is not reported"
  end
end
