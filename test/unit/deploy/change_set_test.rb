# frozen_string_literal: true

require "test_helper"
require_relative "../../support/deploy_fixtures"

# The change set half of the flow of architecture section 9: waiting for the
# change set, the three ways it can come back (no changes, rejected, available),
# the approval, --no-execute, and what is computed before any request is made.
class DeployChangeSetTest < Minitest::Test
  include DeployFixtures
  D = RubyCdk::Deploy
  NAME = D::Deployer::CHANGE_SET_NAME

  def deleted_change_set_ids
    client.calls_to(:delete_change_set).map { |call| call.args[1] }
  end

  def create_request
    requests = client.kwargs_of(:create_change_set)
    assert_equal 1, requests.length, "one change set is created"
    requests.first
  end

  # --- waiting for the change set

  def test_it_waits_while_the_change_set_is_being_created
    client.on(:describe_change_set, described(status: "CREATE_PENDING"), described(status: "CREATE_IN_PROGRESS"),
      described(status: "CREATE_COMPLETE"))

    result = deploy(client, options: unattended)

    assert_equal :deployed, result.outcome
    assert_equal 3, client.calls_to(:describe_change_set).length
  end

  def test_a_change_set_that_is_never_created_is_given_up_on
    client.on(:describe_change_set, described(status: "CREATE_IN_PROGRESS"))
    impatient = D::Poller.new(interval: 1, factor: 1, max_interval: 1, limit: 2, sleep: ->(_seconds) { })

    error = assert_raises(D::WaitTimedOut) { deploy(client, options: unattended, poller: impatient) }

    assert_equal 1, D.exit_code_for(error)
    assert_match(/Stopped waiting: CloudFormation did not finish creating the change set for stack blog/, error.message)
    refute_includes client.operations, :execute_change_set
  end

  # --- no changes

  NO_CHANGE_REASONS = {
    the_cdk_reason: "The submitted information didn't contain changes.",
    the_transform_reason: "No updates are to be performed.",
    the_early_validation_code: "NoChangesInUpdateSet",
    a_reason_that_starts_with_the_cdk_one: "The submitted information didn't contain changes. Other things differ."
  }.freeze

  NO_CHANGE_REASONS.each do |name, reason|
    define_method("test_no_changes_when_cloudformation_answers_#{name}") do
      client.on(:describe_change_set, change_set(status: "FAILED", status_reason: reason))

      result = deploy(client, options: unattended)

      assert_equal :no_changes, result.outcome
      assert_equal 0, result.exit_code
      assert_equal [ CHANGE_SET_ID ], deleted_change_set_ids, "the change set is deleted"
      refute_includes client.operations, :execute_change_set
      refute_includes client.operations, :delete_stack, "the stack is kept"
    end
  end

  def test_no_changes_when_the_change_set_is_empty
    client.on(:describe_change_set, change_set(changes: :none))

    result = deploy(client, options: unattended)

    assert_equal :no_changes, result.outcome
    assert_equal [ CHANGE_SET_ID ], deleted_change_set_ids
    refute_includes client.operations, :execute_change_set
  end

  # The reasons are matched as prefixes, as the CDK matches them
  # (changeSetHasNoChanges): a reason that contains the no-change text in the
  # middle is a rejection like any other.
  def test_a_reason_that_only_contains_the_no_change_text_is_a_rejection
    client.on(:describe_change_set,
      change_set(status: "FAILED", status_reason: "Template error: The submitted information didn't contain changes. Check it."))

    error = assert_raises(D::ChangeSetFailed) { deploy(client, options: unattended) }

    assert_equal 3, D.exit_code_for(error)
    assert_equal [ CHANGE_SET_ID ], deleted_change_set_ids
    refute_includes client.operations, :execute_change_set
  end

  def test_force_against_an_unchanged_stack_says_so_when_there_is_nothing_to_do
    client.stack("blog", template: TEMPLATE)
    # The first describe answers the wait for the older change set of the same
    # name; the second describes the new one, which CloudFormation refuses.
    client.on(:describe_change_set, described(status: "DELETE_COMPLETE"),
      change_set(status: "FAILED", status_reason: "No updates are to be performed."))
    out = D::Fakes::Output.new

    result = deploy(client, out, options: unattended(force: true))

    assert_equal :no_changes, result.outcome
    assert out.announcements.any? { |text| text.include?("--force was given") }
  end

  # --- rejected

  def test_a_rejected_change_set_on_a_fresh_stack_deletes_the_stack_and_exits_3
    client.on(:describe_change_set, change_set(status: "FAILED", status_reason: "Resource type not found: AWS::S3::Buket"))
    out = D::Fakes::Output.new

    error = assert_raises(D::ChangeSetFailed) { deploy(client, out, options: unattended) }

    assert_equal 3, D.exit_code_for(error)
    assert_kind_of RubyCdk::ChangeSetRejected, error
    assert_equal [ CHANGE_SET_ID ], deleted_change_set_ids, "the change set is deleted"
    assert_equal 1, client.calls_to(:delete_stack).length, "and so is the stack a rejected creation made"
    assert_equal "DELETE_COMPLETE", client.stack_record("blog").status
    assert out.failures.one? { |text| text.include?("CloudFormation rejected the change set for stack blog: Resource type not found") },
      "the reason is printed"
    refute_includes client.operations, :execute_change_set
  end

  def test_the_rejection_names_the_command_to_run_after_it
    client.on(:describe_change_set, change_set(status: "FAILED", status_reason: "Transform failed"))

    error = assert_raises(D::ChangeSetFailed) { deploy(client, options: unattended) }

    assert_match(/CloudFormation rejected the change set for stack blog: Transform failed/, error.message)
    assert_match(/run `ruby-cdk deploy blog` again/, error.message)
  end

  def test_the_early_events_of_a_rejection_are_printed_with_the_reason
    client.on(:describe_change_set, change_set(status: "FAILED", status_reason: "AWS::EarlyValidation"))
    client.on(:operation_events, [
      event("VALIDATION_ERROR", logical_id: "Bucket", resource_type: "AWS::S3::Bucket", status_reason: "Unresolved resource dependencies [Server]"),
      event("PROVISIONING_ERROR", logical_id: "Server", resource_type: "AWS::EC2::Instance", status_reason: "Image does not exist")
    ])
    out = D::Fakes::Output.new

    assert_raises(D::ChangeSetFailed) { deploy(client, out, options: unattended) }

    assert_equal [ "blog", CHANGE_SET_ID ], client.calls_to(:operation_events).first.args
    text = out.failures.first
    assert_match(/AWS::EarlyValidation/, text)
    assert_match(/^\s+Bucket \(AWS::S3::Bucket\) VALIDATION_ERROR: Unresolved resource dependencies \[Server\]$/, text)
    assert_match(/^\s+Server \(AWS::EC2::Instance\) PROVISIONING_ERROR: Image does not exist$/, text)
  end

  def test_a_rejected_change_set_on_an_update_keeps_the_stack
    client.stack("blog", template: "{}")
    # The first describe answers the wait for the older change set of the same
    # name; the second describes the new one, which CloudFormation rejected.
    client.on(:describe_change_set, described(status: "DELETE_COMPLETE"),
      change_set(status: "FAILED", status_reason: "No such property"))

    assert_raises(D::ChangeSetFailed) { deploy(client, options: unattended) }

    deleted = deleted_change_set_ids
    assert_equal NAME, deleted.first, "the one left from before, of the same name"
    assert_equal CHANGE_SET_ID, deleted.last, "and the rejected one"
    refute_includes client.operations, :delete_stack
    assert_equal "CREATE_COMPLETE", client.stack_record("blog").status
  end

  def test_early_events_that_cannot_be_read_change_nothing
    [ RuntimeError.new("AccessDenied"), NotImplementedError.new("not offered by this client") ].each do |failure|
      @client = nil
      client.on(:describe_change_set, change_set(status: "FAILED", status_reason: "Wrong shape"))
      client.on(:operation_events, failure)
      out = D::Fakes::Output.new

      error = assert_raises(D::ChangeSetFailed, failure.class.name) { deploy(client, out, options: unattended) }

      assert_equal 3, D.exit_code_for(error)
      assert_match(/Wrong shape/, out.failures.first, "the reason is still printed")
      assert_equal [ CHANGE_SET_ID ], deleted_change_set_ids
    end
  end

  def test_a_refusal_at_the_request_is_reported_the_same_way
    client.on(:create_change_set, lambda { |_call|
      client.stack("blog", status: "REVIEW_IN_PROGRESS")
      raise RubyCdk::ChangeSetRejected, "ValidationError: Template format error: JSON not well-formed"
    })

    error = assert_raises(D::ChangeSetFailed) { deploy(client, options: unattended) }

    assert_equal 3, D.exit_code_for(error)
    assert_match(/Template format error/, error.message)
    assert_equal 1, client.calls_to(:delete_stack).length, "the stack the request brought into REVIEW_IN_PROGRESS is deleted"
    assert_equal "DELETE_COMPLETE", client.stack_record("blog").status
  end

  def test_a_refusal_that_made_no_stack_deletes_nothing
    client.on(:create_change_set, RubyCdk::ChangeSetRejected.new("InsufficientCapabilitiesException: Needs CAPABILITY_IAM"))

    error = assert_raises(D::ChangeSetFailed) { deploy(client, options: unattended) }

    assert_equal 3, D.exit_code_for(error)
    assert_empty client.calls_to(:delete_stack)
  end

  def test_a_change_set_that_cannot_be_executed_is_a_rejection
    answers = [ change_set(execution_status: "UNAVAILABLE"), change_set(execution_status: "OBSOLETE"),
      change_set(status: "DELETE_COMPLETE", changes: :none) ]
    answers.each do |answer|
      @client = nil
      client.on(:describe_change_set, answer)
      out = D::Fakes::Output.new

      error = assert_raises(D::ChangeSetFailed, "#{answer.status} #{answer.execution_status}") { deploy(client, out, options: unattended) }

      assert_equal 3, D.exit_code_for(error)
      assert_match(/cannot be executed/, out.failures.first)
      assert_equal [ CHANGE_SET_ID ], deleted_change_set_ids
    end
  end

  def test_a_refusal_to_execute_is_a_rejection_too
    client.on(:execute_change_set, RubyCdk::ChangeSetRejected.new("InvalidChangeSetStatusException: not executable"))

    error = assert_raises(D::ChangeSetFailed) { deploy(client, options: unattended) }

    assert_equal 3, D.exit_code_for(error)
    assert_match(/not executable/, error.message)
    assert_equal 1, deleted_change_set_ids.length
  end

  # --- approval

  def test_a_refused_approval_on_a_fresh_stack_leaves_nothing_behind_and_the_next_deploy_works
    out = D::Fakes::Output.new(approvals: false)

    error = assert_raises(D::ApprovalRequired) { deploy(client, out, options: D::DeployOptions.new(account: ACCOUNT)) }

    assert_equal 4, D.exit_code_for(error)
    assert_match(/Approval for the changes to stack blog was not given/, error.message)
    assert_match(/--yes/, error.message)
    assert_equal 1, deleted_change_set_ids.length
    assert_equal "DELETE_COMPLETE", client.stack_record("blog").status, "the new stack is deleted with its change set"
    assert_empty client.change_sets
    assert_match(/account #{ACCOUNT} \(#{REGION}\)/, out.questions.first, "the question names the target")

    again = D::Fakes::Output.new(approvals: true)
    result = deploy(client, again, options: D::DeployOptions.new(account: ACCOUNT))

    assert_equal :deployed, result.outcome, "a refused creation is not in the way of the next one"
    assert_equal "CREATE_COMPLETE", client.stack_record("blog").status
  end

  def test_a_refused_approval_on_an_update_keeps_the_stack
    client.stack("blog", template: "{}")
    out = D::Fakes::Output.new(approvals: false)

    error = assert_raises(D::ApprovalRequired) { deploy(client, out, options: D::DeployOptions.new(account: ACCOUNT)) }

    assert_equal 4, D.exit_code_for(error)
    deleted = deleted_change_set_ids
    assert_equal NAME, deleted.first, "the one left from before, of the same name"
    assert_equal 2, deleted.length, "and the refused one"
    refute_includes client.operations, :delete_stack
    assert_equal "CREATE_COMPLETE", client.stack_record("blog").status
  end

  def test_yes_skips_the_question_but_the_changes_are_still_shown
    out = D::Fakes::Output.new(approvals: false)

    assert_equal :deployed, deploy(client, out, options: unattended).outcome

    assert_empty out.questions
    assert_equal [ "Add" ], out.shown_changes.first.map(&:action)
  end

  def test_a_cleanup_that_does_not_finish_is_told_apart_from_the_refusal
    out = D::Fakes::Output.new(approvals: false)
    client.on(:delete_stack, RuntimeError.new("Throttling: rate exceeded"))

    error = assert_raises(D::ApprovalRequired) { deploy(client, out, options: D::DeployOptions.new(account: ACCOUNT)) }

    assert_equal 4, D.exit_code_for(error), "the refusal keeps its exit code"
    assert_match(/cleanup after that did not finish \(Throttling/, error.message)
    assert_match(/remove what is left of it/, error.message)
  end

  # --- no-execute

  def test_no_execute_leaves_the_change_set_and_says_so
    out = D::Fakes::Output.new(approvals: false)

    result = deploy(client, out, options: D::DeployOptions.new(no_execute: true))

    assert_equal :not_executed, result.outcome
    assert_equal 0, result.exit_code
    refute_includes client.operations, :execute_change_set
    assert_empty client.calls_to(:delete_change_set), "the change set stays, for the console"
    assert_equal "REVIEW_IN_PROGRESS", client.stack_record("blog").status
    assert out.announcements.any? { |text| text.include?("left unexecuted (--no-execute)") }
    assert_empty out.questions, "nothing is executed, so nothing is asked"
    assert_equal [ "Add" ], result.changes.map(&:action)
  end

  def test_an_older_change_set_of_the_same_name_is_removed_before_a_new_one
    client.stack("blog", template: "{}")

    deploy(client, options: unattended)

    assert_equal [ [ "blog", NAME ] ], client.calls_to(:delete_change_set).first(1).map(&:args)
  end

  # The name of a change set is unique per stack while it exists, so the one
  # deleted to free the name is waited for, as the CDK waits for it ("deleting
  # may take a bit").
  def test_the_older_change_set_is_waited_for_before_its_name_is_taken
    client.stack("blog", template: "{}")
    client.on(:describe_change_set, change_set(status: "DELETE_IN_PROGRESS"),
      RubyCdk::PreconditionError.new("#{NAME} not found: it is still being deleted"),
      described(status: "CREATE_COMPLETE"))

    deploy(client, options: unattended)

    assert_operator client.operations.index(:delete_change_set), :<, client.operations.index(:describe_change_set),
      "it is deleted first"
    describes = client.calls_to(:describe_change_set)
    assert_equal [ "blog", NAME ], describes.first.args, "the older set is asked for by its name"
    assert_equal 3, describes.length, "polled until gone, then once for the new change set"
    create_at = client.operations.index(:create_change_set)
    assert_operator create_at, :>, 2, "the new change set is created only once the name is free"
  end

  # --- what is computed before any request

  def test_capabilities_are_computed_from_the_template_and_shown_with_the_changes
    named = template(resources: { "Role" => { "Type" => "AWS::IAM::Role", "Properties" => { "RoleName" => "deployer" } } })
    unnamed = template(resources: { "Role" => { "Type" => "AWS::IAM::Role", "Properties" => { "AssumeRolePolicyDocument" => {} } } })

    out = D::Fakes::Output.new
    deploy(client, out, body: named, options: unattended)
    assert_equal %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM], create_request[:capabilities]
    assert_equal [ %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM] ], out.shown_capabilities

    @client = nil
    deploy(client, body: unnamed, options: unattended)
    assert_equal %w[CAPABILITY_IAM], create_request[:capabilities]

    @client = nil
    out = D::Fakes::Output.new
    deploy(client, out, options: unattended)
    assert_equal [], create_request[:capabilities]
    assert_equal [ [] ], out.shown_capabilities
  end

  def test_a_template_of_exactly_the_limit_goes_inline_and_one_byte_more_does_not
    base = JSON.parse(TEMPLATE)
    of_size = lambda do |size|
      JSON.generate(base.merge("Description" => "x" * (size - JSON.generate(base.merge("Description" => "")).bytesize)))
    end

    result = deploy(client, body: of_size.call(51_200), options: unattended)
    assert_equal :deployed, result.outcome
    assert_equal 51_200, create_request[:template].bytesize

    @client = nil
    error = assert_raises(D::TemplateTooLarge) { deploy(client, body: of_size.call(51_201), options: unattended) }

    assert_equal 1, D.exit_code_for(error)
    assert_match(/51201 bytes/, error.message)
    assert_empty client.calls, "nothing is asked of AWS"
  end

  def test_on_failure_is_sent_for_a_creation_only
    deploy(client, options: unattended(on_failure: :rollback))
    assert_equal "ROLLBACK", create_request[:on_stack_failure]

    @client = nil
    deploy(client, options: unattended(on_failure: "DO_NOTHING"))
    assert_equal "DO_NOTHING", create_request[:on_stack_failure]

    @client = nil
    client.stack("blog", template: "{}")
    deploy(client, options: unattended(on_failure: :rollback))
    assert_nil create_request[:on_stack_failure]

    @client = nil
    error = assert_raises(RubyCdk::UsageError) { deploy(client, options: unattended(on_failure: :keep)) }
    assert_match(/DELETE, ROLLBACK or DO_NOTHING/, error.message)
    assert_empty client.calls
  end

  def test_a_parameter_without_a_value_stops_before_any_change_set
    body = template(resources: { "Bucket" => BUCKET.merge("Properties" => { "BucketName" => { "Ref" => "Name" } }) },
      "Parameters" => { "Name" => { "Type" => "String" } })

    error = assert_raises(D::ParametersMissing) { deploy(client, body: body, options: unattended) }

    assert_equal 1, D.exit_code_for(error)
    assert_match(/missing a value: Name/, error.message)
    # The stack is looked up first, as the CDK looks its parameters up before
    # it builds them; what must not happen is a change set.
    assert_equal %i[stack_state], client.operations
    assert_empty client.calls_to(:create_change_set)
  end

  def test_a_template_that_is_not_a_json_object_stops_before_any_request
    [ "not json", "[]", "" ].each do |body|
      @client = nil

      error = assert_raises(D::InvalidTemplate, body.inspect) { deploy(client, body: body, options: unattended) }

      assert_equal 1, D.exit_code_for(error)
      assert_empty client.calls
    end
  end

  def test_the_parameters_given_are_sent_to_the_change_set
    body = template(resources: { "Bucket" => BUCKET.merge("Properties" => { "BucketName" => { "Ref" => "Name" } }) },
      "Parameters" => { "Name" => { "Type" => "String" }, "Size" => { "Type" => "Number", "Default" => 3 } })

    deploy(client, body: body, options: unattended(parameters: { "Name" => "data" }))

    assert_equal [ { parameter_key: "Name", parameter_value: "data" } ], create_request[:parameters]
  end

  # --- the helpers the tests above share

  def client
    @client ||= D::Fakes::CfnClient.new
  end
end
