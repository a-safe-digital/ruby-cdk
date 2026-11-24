# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "ruby_cdk/deploy/sdk_adapters"

# The AWS SDK behind the two ports, on stub_responses, with stub credentials and
# an explicit region (D-024). Nothing here reaches AWS: test_helper has already
# pointed the shared config and credentials files at /dev/null and switched the
# metadata endpoint off, and every request is answered by a stub.
class SdkAdaptersTest < Minitest::Test
  S = RubyCdk::Deploy::Sdk
  ACCOUNT = "111122223333"
  STUB = Aws::Credentials.new("stub", "stub")
  STACK_ID = "arn:aws:cloudformation:eu-west-1:#{ACCOUNT}:stack/blog/id-1"
  CHANGE_SET_ID = "arn:aws:cloudformation:eu-west-1:#{ACCOUNT}:changeSet/ruby-cdk-deploy-change-set/1"
  ValidationError = Aws::CloudFormation::Errors::ValidationError

  # A shared config file for the region tests: the default profile and a named
  # one, in different regions, so that mixing them up shows.
  CONFIG = <<~INI
    [default]
    region = eu-west-1

    [monitoring]
    region = eu-central-1

    [no-region]
    output = json
  INI

  # --- the helpers

  def cfn
    @cfn ||= S.cfn_client(region: "eu-west-1", credentials: STUB, stub_responses: true)
  end

  def store
    @store ||= S.object_store(region: "eu-west-1", credentials: STUB, stub_responses: true)
  end

  def stub_stack(status: "CREATE_COMPLETE", **fields)
    cfn.raw.stub_responses(:describe_stacks,
      { stacks: [ { stack_name: "blog", stack_id: STACK_ID, stack_status: status, creation_time: Time.utc(2026, 1, 1), **fields } ] })
  end

  # An error as AWS answers one: the class the SDK raises, with the message.
  def answered(klass, message)
    klass.new(nil, message)
  end

  def sent(client, operation)
    client.raw.api_requests.reverse.find { |request| request[:operation_name] == operation }[:params]
  end

  # Sets and removes environment variables for the block, and puts them back.
  def with_env(changes)
    before = changes.keys.to_h { |name| [ name, ENV[name] ] }
    changes.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
    yield
  ensure
    before.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
  end

  # No region from anywhere unless the block says so.
  def with_no_region_named
    with_env("AWS_REGION" => nil, "AMAZON_REGION" => nil, "AWS_DEFAULT_REGION" => nil, "AWS_PROFILE" => nil,
      "AWS_CONFIG_FILE" => "/dev/null", "AWS_SHARED_CREDENTIALS_FILE" => "/dev/null", "AWS_SDK_CONFIG_OPT_OUT" => "1") { yield }
  end

  # The config file above, as AWS_CONFIG_FILE, for a block. The credentials file stays at /dev/null.
  def with_config(file_name: "ruby-cdk-config")
    file = Tempfile.new(file_name)
    file.write(CONFIG)
    file.close
    with_env("AWS_CONFIG_FILE" => file.path, "AWS_SHARED_CREDENTIALS_FILE" => "/dev/null", "AWS_SDK_CONFIG_OPT_OUT" => nil,
      "AWS_REGION" => nil, "AMAZON_REGION" => nil, "AWS_DEFAULT_REGION" => nil) { yield file.path }
  ensure
    file&.unlink
  end

  # --- the clients

  def test_the_client_is_the_port_built_with_the_region_given_and_the_credentials_given
    assert_kind_of RubyCdk::Deploy::CfnClient, cfn
    assert_kind_of RubyCdk::Deploy::ObjectStore, store
    assert_equal "eu-west-1", cfn.raw.config.region
    assert_equal "eu-west-1", store.raw.config.region
    assert_equal "stub", cfn.raw.config.credentials.access_key_id, "the stub credentials, not the chain"
    assert_equal "stub", store.raw.config.credentials.access_key_id
  end

  def test_a_profile_narrows_the_client_to_it_and_nothing_else
    with_no_region_named do
      with_work = S.cfn_client(region: "eu-west-1", profile: "work", credentials: STUB, stub_responses: true)

      assert_equal "work", with_work.raw.config.profile
      refute_equal "work", cfn.raw.config.profile, "without one the chain is the SDK's own"
    end
  end

  def test_clients_are_the_two_ports_on_one_region
    pair = S.clients(profile: nil, region: "us-east-1", credentials: STUB, stub_responses: true)

    assert_equal %i[cfn store], S::Clients.members
    assert_kind_of RubyCdk::Deploy::CfnClient, pair.cfn
    assert_kind_of RubyCdk::Deploy::ObjectStore, pair.store
    assert_equal "us-east-1", pair.cfn.raw.config.region
    assert_equal "us-east-1", pair.store.raw.config.region
    assert pair.cfn.raw.config.stub_responses
    assert pair.store.raw.config.stub_responses
  end

  def test_clients_never_builds_a_client_without_a_region
    with_no_region_named do
      assert_raises(RubyCdk::PreconditionError) { S.clients(profile: nil, region: nil, credentials: STUB, stub_responses: true) }
      assert_raises(RubyCdk::PreconditionError) { S.clients(profile: "no-region", region: "", credentials: STUB, stub_responses: true) }
    end
  end

  def test_a_region_the_sdk_does_not_know_is_refused_before_a_client_is_built
    with_no_region_named do
      error = assert_raises(RubyCdk::PreconditionError) { S.clients(profile: nil, region: "mars-west-1", credentials: STUB) }

      assert_match(/"mars-west-1" is not a region the AWS SDK knows/, error.message)
      assert_match(/--region NAME/, error.message)
    end
  end

  # --- the region

  def test_the_region_given_is_the_one_used_whatever_the_profile_says
    with_config do
      assert_equal "us-east-1", S.resolve_region(profile: "monitoring", region: "us-east-1")
      assert_equal "us-east-1", S.resolve_region(profile: nil, region: "us-east-1")
    end
  end

  def test_a_region_given_as_blank_counts_as_none
    with_env("AWS_REGION" => "sa-east-1") do
      assert_equal "sa-east-1", S.resolve_region(profile: nil, region: "  ")
      assert_equal "sa-east-1", S.resolve_region(profile: "monitoring", region: "")
    end
  end

  def test_the_environment_comes_next_in_the_sdk_s_own_order
    with_config do
      with_env("AWS_REGION" => "us-east-1", "AMAZON_REGION" => "us-west-1", "AWS_DEFAULT_REGION" => "us-west-2") do
        assert_equal "us-east-1", S.resolve_region(profile: "monitoring", region: nil), "and before the profile's"
      end
      with_env("AMAZON_REGION" => "us-west-1", "AWS_DEFAULT_REGION" => "us-west-2") do
        assert_equal "us-west-1", S.resolve_region(profile: nil, region: nil)
      end
      with_env("AWS_REGION" => "", "AWS_DEFAULT_REGION" => "us-west-2") do
        assert_equal "us-west-2", S.resolve_region(profile: nil, region: nil), "a blank one is not a region"
      end
    end
  end

  def test_a_region_from_the_environment_is_checked_too
    with_no_region_named do
      with_env("AWS_REGION" => "mars-west-1") do
        error = assert_raises(RubyCdk::PreconditionError) { S.resolve_region(profile: nil, region: nil) }

        assert_match(/not a region the AWS SDK knows/, error.message)
      end
    end
  end

  # The pin the lead asked for: a named profile is never answered with the
  # default profile's region, which is what the wrong SharedConfig call does.
  def test_the_profile_names_its_own_region_never_the_default_profile_s
    with_config do |path|
      refute_match(%r{/\.aws/}, path, "the default paths are never read")

      assert_equal "eu-central-1", S.resolve_region(profile: "monitoring", region: nil)
      assert_equal "eu-west-1", S.resolve_region(profile: nil, region: nil), "and the default profile is the default"
      assert_equal "eu-west-1", S.resolve_region(profile: "default", region: nil)
    end
  end

  def test_the_trap_in_shared_config_is_real_and_this_code_does_not_fall_in_it
    with_config do |path|
      # How the SDK behaves, pinned so that a change in it is noticed:
      without_config = Aws::SharedConfig.new(profile: "monitoring", config_path: path, credentials_path: "/dev/null").region
      the_right_call = Aws::SharedConfig.new(config_enabled: true, config_path: path, credentials_path: "/dev/null").region(profile: "monitoring")
      the_wrong_call = Aws::SharedConfig.new(profile: "monitoring", config_enabled: true, config_path: path, credentials_path: "/dev/null").region

      assert_nil without_config, "the config file is read only with config_enabled"
      assert_equal "eu-central-1", the_right_call, "the profile is an option of region"
      assert_equal "eu-west-1", the_wrong_call, "profile: is ignored by new, so this is the default profile, in silence"
    end
  end

  def test_a_profile_that_names_no_region_and_a_profile_that_does_not_exist_refuse
    with_config do
      with_env("AWS_SDK_CONFIG_OPT_OUT" => nil) do
        missing = assert_raises(RubyCdk::PreconditionError) { S.resolve_region(profile: "no-region", region: nil) }
        assert_match(/the profile no-region names none in the shared config file/, missing.message)
        assert_match(/--region NAME/, missing.message)

        unknown = assert_raises(RubyCdk::PreconditionError) { S.resolve_region(profile: "nobody", region: nil) }
        assert_match(/the profile nobody names none/, unknown.message)
      end
    end
  end

  def test_the_shared_config_is_not_read_when_the_user_told_the_sdk_to_ignore_it
    with_config do
      with_env("AWS_SDK_CONFIG_OPT_OUT" => "1") do
        error = assert_raises(RubyCdk::PreconditionError) { S.resolve_region(profile: "monitoring", region: nil) }

        assert_match(/the profile monitoring names none in the shared config file/, error.message)
      end
    end
  end

  def test_when_nothing_names_a_region_the_command_refuses_and_says_where_one_comes_from
    with_no_region_named do
      error = assert_raises(RubyCdk::PreconditionError) { S.resolve_region(profile: nil, region: nil) }

      assert_match(/No region to deploy to: none was given/, error.message)
      assert_match(/AWS_REGION, AMAZON_REGION, AWS_DEFAULT_REGION/, error.message)
      assert_match(/the default profile names none in the shared config file/, error.message)
      assert_match(/Nothing was changed/, error.message)
      assert_match(/--region NAME/, error.message)
    end
  end

  def test_the_other_partitions_are_regions_too
    with_no_region_named do
      assert_equal "cn-north-1", S.resolve_region(profile: nil, region: "cn-north-1")
      assert_equal "us-gov-west-1", S.resolve_region(profile: nil, region: "us-gov-west-1")
    end
  end

  # --- stacks

  def test_a_stack_is_described_as_the_port_promises
    stub_stack(
      outputs: [ { output_key: "Url", output_value: "https://example.invalid", export_name: "blog-Url" } ],
      enable_termination_protection: true,
      parameters: [ { parameter_key: "Env", parameter_value: "prod" } ],
      tags: [ { key: "Team", value: "a" } ]
    )

    assert_equal :stable, cfn.stack_state("blog")
    assert_equal RubyCdk::Deploy::StackInfo.new(name: "blog", id: STACK_ID, status: "CREATE_COMPLETE",
      outputs: { "Url" => "https://example.invalid" }, termination_protection: true), cfn.stack_info("blog")
    assert_equal({ "Env" => "prod" }, cfn.stack_parameters("blog"))
    assert_equal [ { key: "Team", value: "a" } ], cfn.stack_tags("blog")
  end

  def test_every_group_of_statuses_is_placed_as_the_table_says
    { "UPDATE_ROLLBACK_COMPLETE" => :stable, "ROLLBACK_COMPLETE" => :rollback_complete, "UPDATE_FAILED" => :rollback_failed,
      "UPDATE_IN_PROGRESS" => :busy, "REVIEW_IN_PROGRESS" => :review, "DELETE_COMPLETE" => :absent }.each do |status, state|
      stub_stack(status: status)

      assert_equal state, cfn.stack_state("blog"), status
    end
  end

  def test_a_stack_that_is_not_there_is_absent_in_every_way
    cfn.raw.stub_responses(:describe_stacks, answered(ValidationError, "Stack with id blog does not exist"))
    cfn.raw.stub_responses(:get_template, answered(ValidationError, "Template does not exist for stack blog"))

    assert_equal :absent, cfn.stack_state("blog")
    assert_nil cfn.stack_info("blog")
    assert_nil cfn.get_template("blog")
    assert_equal({}, cfn.stack_parameters("blog"))
    assert_equal [], cfn.stack_tags("blog")
    assert_equal [], cfn.events("blog", after: nil)
  end

  def test_no_stack_in_the_answer_is_a_stack_that_is_not_there
    cfn.raw.stub_responses(:describe_stacks, { stacks: [] })

    assert_equal :absent, cfn.stack_state("blog")
    assert_nil cfn.stack_info("blog")
  end

  def test_another_validation_error_is_a_failure_not_a_missing_stack
    cfn.raw.stub_responses(:describe_stacks, answered(ValidationError, "1 validation error detected: bad stack name"))

    error = assert_raises(RubyCdk::PreconditionError) { cfn.stack_state("blog") }

    assert_match(/ValidationError: 1 validation error detected/, error.message)
    assert_equal "ValidationError", error.code
  end

  def test_a_status_this_tool_does_not_know_is_refused_not_guessed
    stub_stack(status: "SOMETHING_NEW")

    error = assert_raises(RubyCdk::PreconditionError) { cfn.stack_state("blog") }

    assert_match(/"SOMETHING_NEW".*does not know how to place/, error.message)
    assert_match(/Nothing was changed/, error.message)
  end

  # --- change sets

  def test_a_change_set_is_created_with_what_cloudformation_takes
    cfn.raw.stub_responses(:create_change_set, { id: CHANGE_SET_ID, stack_id: STACK_ID })

    answer = cfn.create_change_set("blog", "ruby-cdk-deploy-change-set", template: "{}", change_set_type: :create,
      parameters: [ { parameter_key: "Env", parameter_value: "prod" } ], tags: [ { key: "Team", value: "a" } ],
      capabilities: %w[CAPABILITY_IAM], on_stack_failure: :delete)

    assert_equal CHANGE_SET_ID, answer.id
    assert_equal(
      { stack_name: "blog", change_set_name: "ruby-cdk-deploy-change-set", template_body: "{}", change_set_type: "CREATE",
        parameters: [ { parameter_key: "Env", parameter_value: "prod" } ], tags: [ { key: "Team", value: "a" } ],
        capabilities: %w[CAPABILITY_IAM], on_stack_failure: "DELETE" },
      sent(cfn, :create_change_set)
    )
  end

  def test_an_update_carries_no_on_stack_failure
    cfn.raw.stub_responses(:create_change_set, { id: CHANGE_SET_ID, stack_id: STACK_ID })

    cfn.create_change_set("blog", "cs", template: "{}", change_set_type: "update",
      parameters: [ { "parameter_key" => "Env", "parameter_value" => "prod" } ], tags: [], capabilities: [])

    request = sent(cfn, :create_change_set)
    assert_equal "UPDATE", request[:change_set_type]
    refute request.key?(:on_stack_failure)
    assert_equal [ { parameter_key: "Env", parameter_value: "prod" } ], request[:parameters], "either kind of key is taken"
  end

  # A NoEcho parameter comes back masked, so it is not re-sent: the request
  # asks CloudFormation to keep the deployed value (UsePreviousValue).
  def test_a_parameter_without_a_value_is_sent_as_the_previous_one
    cfn.raw.stub_responses(:create_change_set, { id: CHANGE_SET_ID, stack_id: STACK_ID })

    cfn.create_change_set("blog", "cs", template: "{}", change_set_type: :update,
      parameters: [ { parameter_key: "Pass", use_previous_value: true }, { parameter_key: "Env", parameter_value: "prod" } ],
      tags: [], capabilities: [])

    assert_equal(
      [ { parameter_key: "Pass", use_previous_value: true }, { parameter_key: "Env", parameter_value: "prod" } ],
      sent(cfn, :create_change_set)[:parameters]
    )
  end

  def test_a_refused_change_set_is_the_rejection_and_any_other_failure_is_a_failure
    cfn.raw.stub_responses(:create_change_set, answered(ValidationError, "Template format error"))
    rejected = assert_raises(RubyCdk::ChangeSetRejected) { cfn.create_change_set("blog", "cs", template: "{}", change_set_type: :create, parameters: [], tags: [], capabilities: []) }
    assert_match(/ValidationError: Template format error/, rejected.message)
    refute_kind_of RubyCdk::PreconditionError, rejected, "it is exit 3, not exit 1"

    [ [ Aws::CloudFormation::Errors::AccessDenied, "not allowed" ], [ Aws::CloudFormation::Errors::LimitExceededException, "quota" ] ].each do |klass, message|
      cfn.raw.stub_responses(:create_change_set, answered(klass, message))
      failure = assert_raises(RubyCdk::PreconditionError, klass.name) do
        cfn.create_change_set("blog", "cs", template: "{}", change_set_type: :create, parameters: [], tags: [], capabilities: [])
      end
      refute_kind_of RubyCdk::ChangeSetRejected, failure
    end
  end

  def test_a_change_set_is_described_with_every_page_of_its_changes
    detail = [ { target: { attribute: "Properties", name: "Timeout", requires_recreation: "Never", path: "" } } ]
    cfn.raw.stub_responses(:describe_change_set, [
      { change_set_id: CHANGE_SET_ID, stack_id: STACK_ID, status: "CREATE_COMPLETE", status_reason: nil,
        execution_status: "AVAILABLE", changes: [ { type: "Resource", resource_change: { action: "Add", logical_resource_id: "Bucket",
          resource_type: "AWS::S3::Bucket", replacement: "False", details: detail } } ], next_token: "next" },
      { change_set_id: CHANGE_SET_ID, stack_id: STACK_ID, status: "CREATE_COMPLETE", execution_status: "AVAILABLE",
        changes: [ { type: "Resource", resource_change: { action: "Remove", logical_resource_id: "Old", resource_type: "AWS::SQS::Queue",
          replacement: nil, details: nil } } ] }
    ])

    answer = cfn.describe_change_set("blog", CHANGE_SET_ID)

    assert_equal CHANGE_SET_ID, answer.id
    assert_equal "CREATE_COMPLETE", answer.status
    assert_equal "AVAILABLE", answer.execution_status
    assert_equal %w[Add Remove], answer.changes.map(&:action)
    assert_equal %w[Bucket Old], answer.changes.map(&:logical_id)
    assert_equal "False", answer.changes.first.replacement
    assert_equal [ { target: { attribute: "Properties", name: "Timeout", requires_recreation: "Never", path: "" } } ],
      answer.changes.first.detail, "a plain Hash all the way down, in the shape the SDK names things"
    assert_equal [], answer.changes.last.detail, "no detail is an empty list, as the SDK answers it"
    assert_equal 2, cfn.raw.api_requests.count { |request| request[:operation_name] == :describe_change_set }
    assert_equal "next", cfn.raw.api_requests.select { |request| request[:operation_name] == :describe_change_set }.last[:params][:next_token]
  end

  def test_execution_sends_what_the_engine_asks_and_nothing_that_would_conflict
    cfn.raw.stub_responses(:execute_change_set, {})

    assert_nil cfn.execute_change_set(STACK_ID, CHANGE_SET_ID, disable_rollback: false, retain_except_on_create: true)

    request = sent(cfn, :execute_change_set)
    assert_equal STACK_ID, request[:stack_name]
    assert_equal CHANGE_SET_ID, request[:change_set_name]
    refute request.key?(:disable_rollback), "a creation carries OnStackFailure instead"
    assert_equal true, request[:retain_except_on_create]

    cfn.execute_change_set(STACK_ID, CHANGE_SET_ID, disable_rollback: true, retain_except_on_create: true)
    assert_equal true, sent(cfn, :execute_change_set)[:disable_rollback]
  end

  def test_a_refused_execution_is_the_rejection
    cfn.raw.stub_responses(:execute_change_set, answered(Aws::CloudFormation::Errors::InvalidChangeSetStatusException, "not now"))

    error = assert_raises(RubyCdk::ChangeSetRejected) { cfn.execute_change_set(STACK_ID, CHANGE_SET_ID) }

    assert_match(/not now/, error.message)
  end

  def test_the_simple_calls_send_what_they_are_given
    cfn.raw.stub_responses(:delete_change_set, {})
    cfn.raw.stub_responses(:delete_stack, {})
    cfn.raw.stub_responses(:update_termination_protection, { stack_id: STACK_ID })

    assert_nil cfn.delete_change_set("blog", CHANGE_SET_ID)
    assert_equal({ stack_name: "blog", change_set_name: CHANGE_SET_ID }, sent(cfn, :delete_change_set))
    assert_nil cfn.delete_stack(STACK_ID)
    assert_equal({ stack_name: STACK_ID }, sent(cfn, :delete_stack))
    assert_nil cfn.update_termination_protection(STACK_ID, enabled: true)
    assert_equal({ stack_name: STACK_ID, enable_termination_protection: true }, sent(cfn, :update_termination_protection))
  end

  def test_a_template_and_a_stack_that_has_none
    cfn.raw.stub_responses(:get_template, { template_body: "{}" })
    assert_equal "{}", cfn.get_template("blog")

    cfn.raw.stub_responses(:get_template, answered(ValidationError, "Template does not exist for stack blog"))
    assert_nil cfn.get_template("blog"), "a stack waiting in REVIEW_IN_PROGRESS has no template yet"
  end

  # --- events

  def stack_event(status, seconds_ago:, reason: nil)
    { stack_id: STACK_ID, event_id: "event-#{status}-#{seconds_ago}", stack_name: "blog", logical_resource_id: "Bucket",
      resource_type: "AWS::S3::Bucket", timestamp: Time.now - seconds_ago, resource_status: status, resource_status_reason: reason }
  end

  def test_events_are_the_ones_after_the_moment_oldest_first
    cfn.raw.stub_responses(:describe_stack_events,
      { stack_events: [ stack_event("CREATE_COMPLETE", seconds_ago: 0), stack_event("CREATE_IN_PROGRESS", seconds_ago: 2),
        stack_event("UPDATE_COMPLETE", seconds_ago: 3_600) ] })

    events = cfn.events(STACK_ID, after: nil)

    assert_equal %w[CREATE_IN_PROGRESS CREATE_COMPLETE], events.map(&:resource_status), "an hour ago is before the moment; two seconds is within its clock allowance"
    assert_equal [ "Bucket", "AWS::S3::Bucket" ], [ events.first.logical_id, events.first.resource_type ]
    assert_in_delta Time.now - 2, events.first.timestamp, 1
  end

  def test_events_after_a_moment_that_is_given
    cfn.raw.stub_responses(:describe_stack_events,
      { stack_events: [ stack_event("CREATE_COMPLETE", seconds_ago: 0), stack_event("CREATE_FAILED", seconds_ago: 5, reason: "why"),
        stack_event("CREATE_IN_PROGRESS", seconds_ago: 10) ] })

    events = cfn.events(STACK_ID, after: Time.now - 7)

    assert_equal %w[CREATE_FAILED CREATE_COMPLETE], events.map(&:resource_status)
    assert_equal "why", events.first.status_reason
  end

  def test_events_are_read_page_by_page_until_the_moment
    cfn.raw.stub_responses(:describe_stack_events, [
      { stack_events: [ stack_event("CREATE_COMPLETE", seconds_ago: 0) ], next_token: "next" },
      { stack_events: [ stack_event("CREATE_IN_PROGRESS", seconds_ago: 3), stack_event("UPDATE_COMPLETE", seconds_ago: 86_400) ] }
    ])

    assert_equal %w[CREATE_IN_PROGRESS CREATE_COMPLETE], cfn.events(STACK_ID, after: nil).map(&:resource_status)
    assert_equal 2, cfn.raw.api_requests.count { |request| request[:operation_name] == :describe_stack_events }
  end

  def test_the_events_of_the_early_validation
    cfn.raw.stub_responses(:describe_events, { operation_events: [
      { event_id: "e1", stack_id: STACK_ID, operation_type: "CREATE_STACK", event_type: "VALIDATION_ERROR",
        logical_resource_id: "Bucket", resource_type: "AWS::S3::Buket", timestamp: Time.utc(2026, 1, 1, 12, 0, 2),
        validation_name: "aws:earlyValidation:resourceType", validation_status: "FAILED", validation_status_reason: "Unknown resource type" },
      { event_id: "e2", stack_id: STACK_ID, event_type: "PROVISIONING_ERROR", logical_resource_id: "Bucket", resource_type: "AWS::S3::Bucket",
        timestamp: Time.utc(2026, 1, 1, 12, 0, 1), resource_status: "CREATE_FAILED", resource_status_reason: "quota" }
    ] })

    events = cfn.operation_events("blog", CHANGE_SET_ID)

    assert_equal [ "quota", "aws:earlyValidation:resourceType: Unknown resource type" ], events.map(&:status_reason)
    assert_equal Time.utc(2026, 1, 1, 12, 0, 1), events.first.timestamp, "oldest first"
    assert_equal({ stack_name: "blog", change_set_name: CHANGE_SET_ID, filters: { failed_events: true } }, sent(cfn, :describe_events))
  end

  # --- lists

  def test_stacks_are_listed_page_by_page_without_the_deleted_ones
    summary = lambda { |name, status, id|
      { stack_name: name, stack_id: id, stack_status: status, creation_time: Time.utc(2026, 1, 1), stack_status_reason: nil }
    }
    cfn.raw.stub_responses(:list_stacks, [
      { stack_summaries: [ summary.call("blog", "CREATE_COMPLETE", "arn:blog"), summary.call("gone", "DELETE_COMPLETE", "arn:gone") ],
        next_token: "next" },
      { stack_summaries: [ summary.call("ruby-cdk-it-x", "ROLLBACK_COMPLETE", "arn:it") ] }
    ])

    listed = cfn.list_stacks

    assert_equal [ RubyCdk::Deploy::ListedStack.new(name: "blog", id: "arn:blog", status: "CREATE_COMPLETE"),
      RubyCdk::Deploy::ListedStack.new(name: "ruby-cdk-it-x", id: "arn:it", status: "ROLLBACK_COMPLETE") ], listed
    pages = cfn.raw.api_requests.select { |request| request[:operation_name] == :list_stacks }
    assert_equal [ {}, { next_token: "next" } ], pages.map { |request| request[:params] }
  end

  def test_resources_are_listed_page_by_page
    resource = lambda { |id, status, physical|
      { logical_resource_id: id, physical_resource_id: physical, resource_type: "AWS::S3::Bucket", last_updated_timestamp: Time.utc(2026, 1, 1),
        resource_status: status, resource_status_reason: nil }
    }
    cfn.raw.stub_responses(:list_stack_resources, [
      { stack_resource_summaries: [ resource.call("Bucket", "CREATE_COMPLETE", "data") ], next_token: "next" },
      { stack_resource_summaries: [ resource.call("Old", "DELETE_FAILED", nil) ] }
    ])

    assert_equal [ RubyCdk::Deploy::StackResource.new(logical_id: "Bucket", status: "CREATE_COMPLETE", physical_id: "data"),
      RubyCdk::Deploy::StackResource.new(logical_id: "Old", status: "DELETE_FAILED", physical_id: nil) ], cfn.list_resources(STACK_ID)
  end

  # --- identity

  def test_identity_is_asked_of_sts_with_the_clients_own_region_and_credentials
    cfn.sts.stub_responses(:get_caller_identity, { account: ACCOUNT, arn: "arn:aws:iam::#{ACCOUNT}:user/deployer", user_id: "AIDAEXAMPLE" })

    who = cfn.resolve_identity

    assert_equal RubyCdk::Deploy::Identity.new(account: ACCOUNT, region: "eu-west-1", arn: "arn:aws:iam::#{ACCOUNT}:user/deployer"), who
    assert_equal "eu-west-1", cfn.sts.config.region
    assert_equal "stub", cfn.sts.config.credentials.access_key_id, "the same credentials as the client, so a test stubs both"
  end

  def test_an_identity_that_cannot_be_resolved_is_refused_with_the_way_forward
    cfn.sts.stub_responses(:get_caller_identity, "AccessDenied")

    error = assert_raises(RubyCdk::PreconditionError) { cfn.resolve_identity }

    assert_match(/No account could be resolved from the credentials.*AccessDenied/, error.message)
    assert_match(/--profile NAME, --region NAME/, error.message)
    assert_match(/Nothing was changed/, error.message)
  end

  # --- the object store

  def http(status)
    { status_code: status, headers: {}, body: "" }
  end

  def test_the_owner_of_a_bucket_by_what_s3_answers
    [ [ 200, :mine ], [ 404, :absent ], [ 403, :foreign ] ].each do |status, state|
      store.raw.stub_responses(:head_bucket, http(status))

      assert_equal state, store.bucket_state("ruby-cdk-assets-#{ACCOUNT}-eu-west-1", expected_owner: ACCOUNT), status.to_s
      assert_equal ACCOUNT, sent(store, :head_bucket)[:expected_bucket_owner], "every call names the owner"
    end
  end

  def test_an_answer_that_is_not_about_the_owner_is_a_failure
    store.raw.stub_responses(:head_bucket, http(400))

    error = assert_raises(RubyCdk::PreconditionError) { store.bucket_state("NOT A BUCKET NAME", expected_owner: ACCOUNT) }

    assert_match(/S3/, error.message)
  end

  def test_whether_an_object_is_there
    store.raw.stub_responses(:head_bucket, http(200))
    store.raw.stub_responses(:head_object, http(200))
    assert store.object_exists?("assets", "abc.zip", expected_owner: ACCOUNT)
    assert_equal ACCOUNT, sent(store, :head_object)[:expected_bucket_owner]

    store.raw.stub_responses(:head_object, http(404))
    refute store.object_exists?("assets", "abc.zip", expected_owner: ACCOUNT)

    store.raw.stub_responses(:head_object, http(403))
    error = assert_raises(RubyCdk::PreconditionError) { store.object_exists?("assets", "abc.zip", expected_owner: ACCOUNT) }
    assert_match(/belongs to another account than #{ACCOUNT}.*403 Forbidden/, error.message,
      "a bucket that is not ours raises; a false would read as not uploaded yet")
  end

  def test_put_sends_what_the_cdks_publisher_sends
    store.raw.stub_responses(:put_object, {})

    assert_nil store.put("assets", "abc.zip", body: "zip-bytes", expected_owner: ACCOUNT)

    request = sent(store, :put_object)
    assert_equal ACCOUNT, request[:expected_bucket_owner]
    assert_equal "AES256", request[:server_side_encryption]
    assert_equal "SHA256", request[:checksum_algorithm]
    assert_equal "application/zip", request[:content_type]
    assert_equal "zip-bytes", request[:body]

    store.put("assets", "templates/blog/123.json", body: "{}", expected_owner: ACCOUNT)
    assert_equal "application/json", sent(store, :put_object)[:content_type]
    store.put("assets", "something.else", body: "x", expected_owner: ACCOUNT)
    assert_equal "application/octet-stream", sent(store, :put_object)[:content_type]
  end

  def test_a_put_the_bucket_refuses_is_a_failure
    store.raw.stub_responses(:put_object, "NoSuchBucket")

    error = assert_raises(RubyCdk::PreconditionError) { store.put("nowhere", "abc.zip", body: "x", expected_owner: ACCOUNT) }

    assert_equal "NoSuchBucket", error.code

    store.raw.stub_responses(:put_object, "AccessDenied")
    refused = assert_raises(RubyCdk::PreconditionError) { store.put("theirs", "abc.zip", body: "x", expected_owner: ACCOUNT) }
    assert_match(/belongs to another account than #{ACCOUNT}, or these credentials may not touch it/, refused.message)
    assert_match(/Nothing was uploaded/, refused.message)
  end

  # --- when AWS cannot be reached, or the credentials cannot be found

  def test_a_client_is_never_built_without_a_region
    error = assert_raises(RubyCdk::PreconditionError) { S.cfn_client(region: nil, credentials: STUB, stub_responses: true) }

    assert_match(/does not accept the region nil.*--region NAME/, error.message)
  end

  def test_aws_that_cannot_be_reached_is_a_failure_that_says_so
    cfn.raw.stub_responses(:describe_stacks, Seahorse::Client::NetworkingError.new(SocketError.new("connection refused")))

    error = assert_raises(RubyCdk::PreconditionError) { cfn.stack_state("blog") }

    assert_match(/AWS could not be reached \(connection refused\)/, error.message)
    assert_nil error.code, "there was no answer"
  end

  def test_credentials_that_cannot_be_found_are_a_failure_that_says_so
    cfn.raw.stub_responses(:describe_stacks, Aws::Errors::NoSuchProfileError.new)

    error = assert_raises(RubyCdk::PreconditionError) { cfn.stack_state("blog") }

    assert_match(/credentials could not be found or used \(NoSuchProfileError/, error.message)
  end

  def test_an_error_the_sdk_does_not_document_is_not_disguised
    cfn.raw.stub_responses(:describe_stacks, ->(_context) { raise ArgumentError, "a bug of ours" })

    error = assert_raises(ArgumentError) { cfn.stack_state("blog") }

    assert_equal "a bug of ours", error.message, "a bug is reported as the bug it is"
  end

  def test_the_events_of_a_stack_that_is_gone_are_none
    cfn.raw.stub_responses(:describe_stack_events, answered(ValidationError, "Stack with id blog does not exist"))

    assert_equal [], cfn.events("blog", after: nil)

    cfn.raw.stub_responses(:describe_stack_events, answered(ValidationError, "1 validation error detected"))
    assert_raises(RubyCdk::PreconditionError) { cfn.events("blog", after: nil) }
  end

  def test_a_bucket_that_cannot_be_asked_about_is_a_failure_that_says_so
    store.raw.stub_responses(:head_bucket, Seahorse::Client::NetworkingError.new(SocketError.new("connection refused")))

    error = assert_raises(RubyCdk::PreconditionError) { store.bucket_state("assets", expected_owner: ACCOUNT) }

    assert_match(/AWS could not be reached/, error.message)
  end

  def test_a_shared_config_that_cannot_be_read_is_a_failure_that_names_the_region_option
    file = Tempfile.new("ruby-cdk-config-binary")
    file.binmode
    file.write("\x00\x01\xFF\xFE not text".b)
    file.close
    with_env("AWS_CONFIG_FILE" => file.path, "AWS_SHARED_CREDENTIALS_FILE" => "/dev/null", "AWS_SDK_CONFIG_OPT_OUT" => nil,
      "AWS_REGION" => nil, "AMAZON_REGION" => nil, "AWS_DEFAULT_REGION" => nil) do
      error = assert_raises(RubyCdk::PreconditionError) { S.resolve_region(profile: nil, region: nil) }

      assert_match(/shared config file could not be read for a region/, error.message)
      assert_match(/--region NAME/, error.message)
    end
  ensure
    file&.unlink
  end

  def test_the_adapters_answer_every_method_of_their_ports
    { RubyCdk::Deploy::CfnClient => S::CloudFormationClient, RubyCdk::Deploy::ObjectStore => S::ObjectStoreClient }.each do |port, answers|
      port.public_instance_methods(false).each do |name|
        assert answers.method_defined?(name), "#{answers} does not answer #{name}"
        refute_equal port, answers.instance_method(name).owner, "#{answers}##{name} is only the port's refusal"
      end
    end
  end
end
