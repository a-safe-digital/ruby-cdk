# frozen_string_literal: true

require "test_helper"
require_relative "../../support/deploy_fixtures"

# The fakes the engine's tests stand on: what they answer by themselves, what a
# test scripts, and what they keep for the assertions. They are tested here so
# that an engine test that passes means something.
class DeployFakesTest < Minitest::Test
  include DeployFixtures
  D = RubyCdk::Deploy
  STACK_ID = "arn:aws:cloudformation:eu-west-1:111122223333:stack/blog/kept-id"

  def client
    @client ||= D::Fakes::CfnClient.new
  end

  # --- scripted answers

  def test_scripted_answers_are_consumed_in_order_and_the_last_one_repeats
    client.on(:stack_state, :busy, :busy, :stable)

    assert_equal [ :busy, :busy, :stable, :stable ], 4.times.map { client.stack_state("blog") }
  end

  def test_a_scripted_exception_is_raised
    client.on(:get_template, RuntimeError.new("no template"))

    error = assert_raises(RuntimeError) { client.get_template("blog") }

    assert_equal "no template", error.message
    assert_raises(RuntimeError, "and again: the last answer repeats") { client.get_template("blog") }
  end

  def test_a_scripted_callable_is_called_with_the_call
    client.on(:stack_parameters, lambda { |call|
      { call.args.first => "from #{call.operation}" }
    })

    assert_equal({ "blog" => "from stack_parameters" }, client.stack_parameters("blog"))
  end

  def test_an_operation_nobody_scripted_answers_from_the_stack
    client.stack("blog", id: STACK_ID, status: "UPDATE_ROLLBACK_COMPLETE", template: TEMPLATE, parameters: { "Env" => "prod" },
      tags: [ { key: "Team", value: "a" } ], outputs: { "Url" => "https://example.invalid" }, termination_protection: true)

    assert_equal :stable, client.stack_state("blog")
    assert_equal D::StackInfo.new(name: "blog", id: STACK_ID, status: "UPDATE_ROLLBACK_COMPLETE",
      outputs: { "Url" => "https://example.invalid" }, termination_protection: true), client.stack_info("blog")
    assert_equal TEMPLATE, client.get_template("blog")
    assert_equal({ "Env" => "prod" }, client.stack_parameters("blog"))
    assert_equal [ { key: "Team", value: "a" } ], client.stack_tags("blog")
  end

  def test_an_absent_stack_is_absent_in_every_way
    assert_equal :absent, client.stack_state("nowhere")
    assert_nil client.stack_info("nowhere")
    assert_nil client.get_template("nowhere")
    assert_equal({}, client.stack_parameters("nowhere"))
    assert_equal [], client.stack_tags("nowhere")
    assert_equal [], client.events("nowhere", after: nil)
    assert_equal [], client.list_resources("nowhere")
    assert_equal [], client.operation_events("nowhere", "cs")
    assert_equal [], client.list_stacks
  end

  def test_a_stack_is_found_by_its_name_or_by_its_id
    client.stack("blog", id: STACK_ID)

    assert_equal STACK_ID, client.stack_info(STACK_ID).id
    assert_equal "blog", client.stack_info(STACK_ID).name
    assert_equal :stable, client.stack_state(STACK_ID)
  end

  # --- the small state under the scripts

  def test_a_create_change_set_brings_a_stack_into_review_in_progress
    answer = client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :create, parameters: [],
      tags: [], capabilities: %w[CAPABILITY_IAM], on_stack_failure: "DELETE")

    assert_match(%r{changeSet/a-name/\d+\z}, answer.id)
    record = client.stack_record("blog")
    assert_equal "REVIEW_IN_PROGRESS", record.status
    assert_equal TEMPLATE, record.template
    created = client.change_sets[answer.id]
    assert_equal :create, created.type
    assert_equal %w[CAPABILITY_IAM], created.capabilities
    assert_equal "DELETE", created.on_stack_failure
  end

  # The template placed in the bucket is not a body the fake can compare, so
  # the set keeps the URL and is never marked empty for it.
  def test_a_change_set_created_with_a_template_url_records_it_and_no_body
    url = "https://bucket.s3.eu-west-1.amazonaws.com/templates/blog/abc.json"
    answer = client.create_change_set("blog", "a-name", template: nil, change_set_type: :create, parameters: [],
      tags: [], capabilities: [], template_url: url)

    record = client.change_sets[answer.id]
    assert_equal url, record.template_url
    assert_nil record.template
    assert_equal({ template: nil, template_url: url }, client.kwargs_of(:create_change_set).first.slice(:template, :template_url))
    assert_equal "CREATE_COMPLETE", client.describe_change_set("blog", answer.id).status
  end

  def test_executing_a_change_set_ends_in_the_status_chosen_and_applies_it_to_the_stack
    client.stack("blog", id: STACK_ID, template: "{}", outputs: { "Url" => "kept" })
    answer = client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :update,
      parameters: [ { parameter_key: "Env", parameter_value: "prod" } ], tags: [ { key: "Team", value: "b" } ], capabilities: [])
    client.execute_change_set(STACK_ID, answer.id, disable_rollback: true, retain_except_on_create: false)

    assert_equal "UPDATE_COMPLETE", client.stack_record("blog").status
    assert_equal TEMPLATE, client.stack_record("blog").template
    assert_equal({ "Env" => "prod" }, client.stack_record("blog").parameters)
    assert_equal [ { key: "Team", value: "b" } ], client.stack_record("blog").tags
    assert_equal({ "Url" => "kept" }, client.stack_record("blog").outputs)
    assert_equal [ { name: STACK_ID, change_set_id: answer.id, disable_rollback: true, retain_except_on_create: false } ], client.executions
  end

  def test_a_creation_ends_in_create_complete_unless_the_test_chooses_otherwise
    client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :create, parameters: [], tags: [], capabilities: [])
    client.execute_change_set("blog", client.change_sets.keys.first)
    assert_equal "CREATE_COMPLETE", client.stack_record("blog").status

    client.execute_result("ROLLBACK_COMPLETE")
    client.create_change_set("blog", "again", template: TEMPLATE, change_set_type: :create, parameters: [], tags: [], capabilities: [])
    client.execute_change_set("blog", client.change_sets.keys.last)
    assert_equal "ROLLBACK_COMPLETE", client.stack_record("blog").status
    assert_equal :rollback_complete, client.stack_state("blog")
  end

  def test_a_described_change_set_is_ready_unless_the_test_scripts_it
    client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :create, parameters: [], tags: [], capabilities: [])
    id = client.change_sets.keys.first

    ready = client.describe_change_set("blog", id)

    assert_equal "CREATE_COMPLETE", ready.status
    assert_equal "AVAILABLE", ready.execution_status
    assert_equal [ "Add" ], ready.changes.map(&:action)
    client.on(:describe_change_set, change_set(status: "FAILED", status_reason: "scripted"))
    assert_equal "FAILED", client.describe_change_set("blog", id).status
  end

  # CloudFormation refuses a change set that would change nothing: the set is
  # created FAILED with the reason (fake-cloudformation.ts in the CDK's CLI
  # answers the same). A create on a stack that has no template yet is never
  # empty.
  def test_an_update_change_set_that_would_change_nothing_is_created_failed_like_cloudformation_s
    client.stack("blog", template: TEMPLATE)

    answer = client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :update,
      parameters: [], tags: [], capabilities: [])
    answer_of = client.describe_change_set("blog", answer.id)

    assert_equal "FAILED", answer_of.status
    assert_equal "The submitted information didn't contain changes.", answer_of.status_reason
    assert_empty answer_of.changes
  end

  def test_an_update_change_set_with_a_different_template_is_ready
    client.stack("blog", template: "{}")

    answer = client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :update,
      parameters: [], tags: [], capabilities: [])

    assert_equal "CREATE_COMPLETE", client.describe_change_set("blog", answer.id).status
  end

  def test_a_change_set_that_is_gone_answers_as_deleted
    client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :create, parameters: [], tags: [], capabilities: [])
    id = client.change_sets.keys.first
    client.delete_change_set("blog", id)

    answer = client.describe_change_set("blog", id)

    assert_equal "DELETE_COMPLETE", answer.status, "as CloudFormation answers for a deleted set"
  end

  def test_deleting_a_stack_ends_in_delete_complete_and_it_stops_being_listed
    client.stack("blog", id: STACK_ID)
    client.stack("other", id: "#{STACK_ID}-other", status: "ROLLBACK_COMPLETE")

    listed = client.list_stacks
    assert_equal %w[blog other], listed.map(&:name)
    assert_equal [ STACK_ID, "#{STACK_ID}-other" ], listed.map(&:id)

    client.delete_stack(STACK_ID)

    assert_equal "DELETE_COMPLETE", client.stack_record("blog").status
    assert_equal :absent, client.stack_state("blog")
    assert_equal %w[other], client.list_stacks.map(&:name), "by ID it can still be described, as in CloudFormation"
    assert_equal STACK_ID, client.stack_info(STACK_ID).id
  end

  def test_a_protected_stack_is_not_deleted
    client.stack("blog", termination_protection: true)

    error = assert_raises(RubyCdk::PreconditionError) { client.delete_stack("blog") }

    assert_match(/protected from deletion/, error.message)
    assert_equal "CREATE_COMPLETE", client.stack_record("blog").status
  end

  def test_protection_is_set_by_the_call_that_sets_it
    client.stack("blog", id: STACK_ID)

    client.update_termination_protection(STACK_ID, enabled: true)

    assert client.stack_record("blog").termination_protection
    assert_equal [ { enabled: true } ], client.calls_to(:update_termination_protection).map(&:kwargs)
  end

  def test_a_change_set_can_be_deleted_and_a_stack_lists_its_resources
    client.stack("blog", resources: [ D::StackResource.new(logical_id: "Bucket", status: "CREATE_COMPLETE", physical_id: "data") ])
    answer = client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :create, parameters: [], tags: [], capabilities: [])

    client.delete_change_set("blog", answer.id)

    assert_empty client.change_sets
    assert_equal [ "Bucket" ], client.list_resources("blog").map(&:logical_id)
  end

  def test_events_are_kept_in_order_and_answered_after_a_moment
    client.emit("blog", "CREATE_IN_PROGRESS")
    client.emit("blog", "CREATE_FAILED", logical_id: "Bucket", resource_type: "AWS::S3::Bucket", status_reason: "why")
    client.emit("blog", "ROLLBACK_IN_PROGRESS")

    events = client.events("blog", after: nil)

    assert_equal %w[CREATE_IN_PROGRESS CREATE_FAILED ROLLBACK_IN_PROGRESS], events.map(&:resource_status)
    assert_equal events.map(&:timestamp), events.map(&:timestamp).sort, "oldest first"
    assert_equal 3, events.map(&:timestamp).uniq.length, "no two share a moment"
    assert_equal %w[CREATE_FAILED ROLLBACK_IN_PROGRESS], client.events("blog", after: events.first.timestamp).map(&:resource_status)
    assert_equal [], client.events("blog", after: events.last.timestamp)
    assert_equal "AWS::S3::Bucket", events[1].resource_type
    assert_equal "AWS::CloudFormation::Stack", events[0].resource_type, "the stack's own event"
  end

  def test_a_stack_registered_again_keeps_its_id_and_its_events
    client.stack("blog", id: STACK_ID)
    client.emit("blog", "CREATE_COMPLETE")

    client.stack("blog", status: "UPDATE_COMPLETE")

    assert_equal STACK_ID, client.stack_record("blog").id
    assert_equal "UPDATE_COMPLETE", client.stack_record("blog").status
    assert_equal 1, client.stack_record("blog").events.length
  end

  def test_identity_is_what_the_fake_was_given
    who = identity(account: "999988887777", region: "us-east-1")

    assert_equal who, D::Fakes::CfnClient.new(identity: who).resolve_identity
    assert_equal "111122223333", client.resolve_identity.account
  end

  # --- what is kept for the assertions

  def test_every_call_is_kept_with_its_arguments
    client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :update, parameters: [], tags: [],
      capabilities: %w[CAPABILITY_IAM])
    client.stack_state("blog")
    client.stack_state("other")

    assert_equal %i[create_change_set stack_state stack_state], client.operations
    call = client.calls.first
    assert_equal :create_change_set, call.operation
    assert_equal [ "blog", "a-name" ], call.args
    assert_equal %w[CAPABILITY_IAM], call.kwargs[:capabilities]
    assert_equal %i[update], client.calls_to(:create_change_set).map { |kept| kept.kwargs[:change_set_type] }
    assert_equal [ { change_set_type: :update } ], client.kwargs_of(:create_change_set).map { |kwargs| kwargs.slice(:change_set_type) }
    assert_equal "other", client.last(:stack_state).args.first
    assert_nil client.last(:delete_stack)
  end

  # --- the example in the fakes' own comment

  def test_the_example_of_a_rejected_change_set_on_a_stack_whose_creation_failed
    client.stack("blog", status: "ROLLBACK_COMPLETE")
    client.on(:describe_change_set, change_set(status: "FAILED", status_reason: "wrong type"))
    out = D::Fakes::Output.new(approvals: false)

    error = assert_raises(D::ChangeSetFailed) do
      D::Deployer.new(client: client, store: D::Fakes::ObjectStore.new, output: out, poller: D::Poller.instant,
        operation_poller: D::Poller.instant).deploy(stack: Stack.new, template: TEMPLATE, identity: client.identity,
          options: D::DeployOptions.new(account: ACCOUNT))
    end

    assert_match(/wrong type/, error.message)
    assert_equal %i[stack_state stack_info delete_stack stack_state create_change_set describe_change_set stack_info
      operation_events delete_change_set stack_state delete_stack stack_state], client.operations
    assert_equal "DELETE_COMPLETE", client.stack_record("blog").status
  end

  def test_a_create_change_set_after_a_deletion_brings_a_new_stack_with_a_new_id
    client.stack("blog", id: STACK_ID)
    client.delete_stack(STACK_ID)

    client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :create, parameters: [], tags: [], capabilities: [])

    assert_equal "REVIEW_IN_PROGRESS", client.stack_record("blog").status
    refute_equal STACK_ID, client.stack_record("blog").id, "a deleted stack and the next one are two stacks"
    assert_equal TEMPLATE, client.get_template("blog")
  end

  def test_a_create_change_set_on_a_stack_waiting_in_review_keeps_its_id
    client.stack("blog", id: STACK_ID, status: "REVIEW_IN_PROGRESS")

    client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :create, parameters: [], tags: [], capabilities: [])

    assert_equal STACK_ID, client.stack_record("blog").id
  end

  def test_an_update_change_set_leaves_the_stack_as_it_is
    client.stack("blog", id: STACK_ID, status: "ROLLBACK_COMPLETE", template: "{}")

    client.create_change_set("blog", "a-name", template: TEMPLATE, change_set_type: :update, parameters: [], tags: [], capabilities: [])

    assert_equal "ROLLBACK_COMPLETE", client.stack_record("blog").status
    assert_equal "{}", client.get_template("blog")
  end

  # --- the object store

  def test_the_object_store_knows_who_owns_a_bucket
    store = D::Fakes::ObjectStore.new.bucket("assets", owner: ACCOUNT).bucket("theirs", owner: "999988887777")

    assert_equal :mine, store.bucket_state("assets", expected_owner: ACCOUNT)
    assert_equal :foreign, store.bucket_state("theirs", expected_owner: ACCOUNT)
    assert_equal :absent, store.bucket_state("nowhere", expected_owner: ACCOUNT)
  end

  def test_a_bucket_that_is_not_ours_stops_the_operation
    store = D::Fakes::ObjectStore.new.bucket("theirs", owner: "999988887777")

    error = assert_raises(RubyCdk::PreconditionError) { store.put("theirs", "k.zip", body: "x", expected_owner: ACCOUNT) }

    assert_match(/belongs to another account than #{ACCOUNT}/, error.message)
    assert_raises(RubyCdk::PreconditionError) { store.object_exists?("theirs", "k.zip", expected_owner: ACCOUNT) }
    assert_raises(RubyCdk::PreconditionError) { store.put("nowhere", "k.zip", body: "x", expected_owner: ACCOUNT) }
    assert_empty store.objects
  end

  def test_objects_go_in_and_are_found_with_the_owner_on_every_call
    store = D::Fakes::ObjectStore.new.bucket("assets")

    refute store.object_exists?("assets", "k.zip", expected_owner: ACCOUNT)
    store.put("assets", "k.zip", body: "bytes", expected_owner: ACCOUNT)

    assert store.object_exists?("assets", "k.zip", expected_owner: ACCOUNT)
    assert_equal({ [ "assets", "k.zip" ] => "bytes" }, store.objects)
    assert_equal %i[object_exists? put object_exists?], store.operations
    assert_equal [ ACCOUNT ], store.calls.map { |call| call.kwargs[:expected_owner] }.uniq
  end

  # --- the output

  def test_the_output_keeps_everything_the_engine_said
    out = D::Fakes::Output.new(approvals: [ true, false ], confirmations: [ "blog" ])

    assert_equal true, out.ask("first?")
    assert_equal false, out.ask("second?"), "the last answer repeats"
    assert_equal true, out.confirm("blog")
    assert_equal false, out.confirm("other"), "a confirmation is the text, not a truthy answer"
    out.target(account: ACCOUNT, region: "eu-west-1", profile: nil)
    out.changes([ change ], capabilities: %w[CAPABILITY_IAM])
    out.outputs({ "Url" => "x" })
    out.retained([])
    out.announce("said")
    out.failure("failed")
    out.event(event("CREATE_COMPLETE"))

    assert_equal %i[ask ask confirm confirm target changes outputs retained announce failure event], out.calls.map(&:operation)
    assert_equal [ { account: ACCOUNT, region: "eu-west-1", profile: nil } ], out.targets
    assert_equal [ "first?", "second?" ], out.questions
    assert_equal [ [ change ] ], out.shown_changes
    assert_equal [ %w[CAPABILITY_IAM] ], out.shown_capabilities
    assert_equal [ { "Url" => "x" } ], out.shown_outputs
    assert_equal [], out.shown_retained
    assert_equal [ "said" ], out.announcements
    assert_equal [ "failed" ], out.failures
    assert_equal "CREATE_COMPLETE", out.shown_events.first.resource_status
    assert_equal 1, out.said(:announce).length
    assert_includes out.transcript, "said"
  end

  def test_an_output_that_is_not_told_otherwise_refuses_everything
    out = D::Fakes::Output.new

    refute out.ask("yes?")
    refute out.confirm("blog")
    assert_equal false, D::Fakes::Output.new(approvals: "yes").ask("yes?"), "a string is not the boolean true"
  end
end
