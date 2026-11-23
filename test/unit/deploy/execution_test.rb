# frozen_string_literal: true

require "test_helper"
require "fileutils"
require_relative "../../support/deploy_fixtures"

# What happens after the approval (architecture section 9): the execution, the
# events followed to a terminal status, the outputs, termination protection, and
# an operation that fails, which ends in a result with exit code 5 and the
# resources that failed.
class DeployExecutionTest < Minitest::Test
  include DeployFixtures
  D = RubyCdk::Deploy

  OUTPUTS = { "Url" => "https://example.invalid", "Arn" => "arn:aws:s3:::data" }.freeze

  # Deploys with an outputs file and answers [result, what the file holds].
  def with_output_file(client, out, **options)
    path = File.join(Dir.tmpdir, "ruby-cdk-outputs-#{object_id}.json")
    result = deploy(client, out, options: unattended(outputs_file: path, **options))
    written = File.read(path)
    FileUtils.rm_f(path)
    [ result, written ]
  end

  def failure_text(client, **setup)
    out = D::Fakes::Output.new
    result = deploy(client, out, **setup)
    assert_equal :failed, result.outcome
    assert_equal 5, result.exit_code
    assert_equal 1, out.failures.length, "one failure is reported, in one piece"
    [ result, out.failures.first ]
  end

  # --- events

  def test_events_are_printed_as_they_arrive_in_order_and_never_twice
    first = event("CREATE_IN_PROGRESS")
    second = event("CREATE_IN_PROGRESS", logical_id: "Bucket", resource_type: "AWS::S3::Bucket")
    third = event("CREATE_COMPLETE", logical_id: "Bucket", resource_type: "AWS::S3::Bucket")
    last = event("CREATE_COMPLETE")
    client.on(:events, [ first, second ], [ second, third, last ])
    out = D::Fakes::Output.new

    deploy(client, out, options: unattended)

    assert_equal [ first, second, third, last ], out.shown_events
    assert_equal 2, client.calls_to(:events).length
  end

  def test_the_last_events_are_read_after_the_stack_has_settled
    client.on(:stack_state, :absent, :busy, :stable)
    client.on(:events, [ event("CREATE_IN_PROGRESS") ], [ event("CREATE_COMPLETE") ])
    out = D::Fakes::Output.new

    result = deploy(client, out, options: unattended)

    assert_equal :deployed, result.outcome
    assert_equal %w[CREATE_IN_PROGRESS CREATE_COMPLETE], out.shown_events.map(&:resource_status)
    assert_equal %i[stack_state events stack_info], client.operations.last(3),
      "the events are read one last time before the outputs"
  end

  def test_an_update_that_rolled_back_is_a_failure_even_though_the_stack_is_stable_again
    client.stack("blog")
    client.execute_result("UPDATE_ROLLBACK_COMPLETE")

    result = deploy(client, options: unattended)

    assert_equal :failed, result.outcome, "a stable stack is not the same thing as a successful update"
    assert_equal 5, result.exit_code
    assert_equal "UPDATE_ROLLBACK_COMPLETE", client.stack_record("blog").status
  end

  def test_events_that_cannot_be_read_are_announced_once_and_do_not_stop_the_deploy
    client.on(:events, RuntimeError.new("AccessDenied: not allowed"))
    out = D::Fakes::Output.new

    result = deploy(client, out, options: unattended)

    assert_equal :deployed, result.outcome
    assert_equal 1, client.calls_to(:events).length, "they are not asked for again and again"
    assert out.announcements.any? { |text| text.include?("could not be read (AccessDenied: not allowed)") }
  end

  # --- an operation that fails

  def test_a_failed_creation_is_a_result_with_exit_code_5_and_names_what_failed
    client.stack("blog", status: "REVIEW_IN_PROGRESS")
    client.execute_result("ROLLBACK_COMPLETE")
    client.emit("blog", "CREATE_IN_PROGRESS", logical_id: "Bucket", resource_type: "AWS::S3::Bucket")
    client.emit("blog", "CREATE_FAILED", logical_id: "Bucket", resource_type: "AWS::S3::Bucket", status_reason: "Name already exists in this region")
    client.emit("blog", "ROLLBACK_IN_PROGRESS", status_reason: "The following resource(s) failed to create: [Bucket]")
    client.emit("blog", "ROLLBACK_COMPLETE")

    result, text = failure_text(client, options: unattended)

    assert_equal({}, result.outputs)
    assert_match(/Stack blog ended in ROLLBACK_COMPLETE: its creation failed and was rolled back/, text)
    assert_match(/^\s+Bucket \(AWS::S3::Bucket\) CREATE_FAILED: Name already exists in this region$/, text)
    assert_match(/run `ruby-cdk deploy blog` again: the failed stack is deleted and created again/, text)
    assert_equal 1, text.scan(/Bucket \(/).length, "the stack's own summary of the failure is not repeated"
  end

  def test_a_creation_that_cloudformation_deleted_on_failure_is_reported_as_gone
    client.stack("blog", status: "REVIEW_IN_PROGRESS")
    client.execute_result("DELETE_COMPLETE")
    client.emit("blog", "CREATE_FAILED", logical_id: "Bucket", resource_type: "AWS::S3::Bucket", status_reason: "Invalid bucket name")

    result, text = failure_text(client, options: unattended)

    assert_nil result.stack_id
    assert_match(/Stack blog is gone: its creation failed, and CloudFormation deleted it as its change set asked/, text)
    assert_match(/CREATE_FAILED: Invalid bucket name/, text)
  end

  def test_a_failed_update_is_a_result_with_exit_code_5
    client.stack("blog")
    client.execute_result("UPDATE_ROLLBACK_COMPLETE")
    client.emit("blog", "UPDATE_FAILED", logical_id: "Bucket", resource_type: "AWS::S3::Bucket", status_reason: "Something went wrong")

    _result, text = failure_text(client, options: unattended)

    assert_match(/Stack blog ended in UPDATE_ROLLBACK_COMPLETE: the operation was rolled back/, text)
    assert_match(/UPDATE_FAILED: Something went wrong/, text)
    assert_match(/run `ruby-cdk deploy blog` again/, text)
  end

  def test_an_update_whose_rollback_failed_says_how_to_repair_it
    client.stack("blog")
    client.execute_result("UPDATE_ROLLBACK_FAILED")

    _result, text = failure_text(client, options: unattended)

    assert_match(/ended in UPDATE_ROLLBACK_FAILED, and has to be repaired/, text)
    assert_match(/Continue update rollback/, text)
    assert_match(/No resource reported a failure/, text)
  end

  def test_an_execution_that_never_started_is_a_failure
    client.on(:stack_state, :absent, :review)

    _result, text = failure_text(client, options: unattended)

    assert_match(/still in REVIEW_IN_PROGRESS: the execution of its change set did not start/, text)
  end

  def test_the_status_from_before_the_execution_is_not_believed_at_once
    client.on(:stack_state, :absent, :review, :review, :review, :stable)

    result = deploy(client, options: unattended)

    assert_equal :deployed, result.outcome, "the CDK gives a stale read three chances to catch up"
    assert_equal 5, client.calls_to(:stack_state).length
  end

  def test_an_operation_that_does_not_finish_is_given_up_on_with_exit_1
    client.execute_result("CREATE_IN_PROGRESS")
    impatient = D::Poller.new(interval: 1, factor: 1, max_interval: 1, limit: 2, sleep: ->(_seconds) { })

    error = assert_raises(D::WaitTimedOut) { deploy(client, options: unattended, operation_poller: impatient) }

    assert_equal 1, D.exit_code_for(error)
    assert_match(/Stopped waiting: the operation on stack blog did not finish/, error.message)
    assert_match(/goes on in AWS/, error.message)
  end

  # --- outputs

  def test_outputs_are_printed_written_to_the_file_and_returned
    client.stack("blog", status: "REVIEW_IN_PROGRESS", outputs: OUTPUTS)
    out = D::Fakes::Output.new

    result, written = with_output_file(client, out)

    assert_equal OUTPUTS, result.outputs
    assert_equal [ OUTPUTS ], out.shown_outputs
    assert_equal "#{JSON.pretty_generate(OUTPUTS)}\n", written
    assert_equal client.stack_record("blog").id, result.stack_id
    assert_equal [ "Add" ], result.changes.map(&:action)
  end

  def test_no_outputs_means_nothing_printed_and_an_empty_file
    out = D::Fakes::Output.new

    result, written = with_output_file(client, out)

    assert_equal({}, result.outputs)
    assert_equal [ {} ], out.shown_outputs
    assert_equal "{}\n", written
  end

  # --- termination protection

  def test_a_stack_that_asks_for_protection_is_protected_before_it_is_executed
    result = deploy(client, stack: Stack.new(termination_protection: true), options: unattended)

    assert_equal :deployed, result.outcome
    calls = client.calls_to(:update_termination_protection)
    assert_equal [ { enabled: true } ], calls.map(&:kwargs)
    assert_operator client.operations.index(:update_termination_protection), :<, client.operations.index(:execute_change_set)
    assert client.stack_record("blog").termination_protection
  end

  def test_a_stack_that_does_not_ask_for_protection_is_left_alone
    deploy(client, options: unattended)

    assert_empty client.calls_to(:update_termination_protection)
  end

  def test_protection_is_reconciled_before_an_update_in_both_directions
    client.stack("blog", termination_protection: false)
    deploy(client, stack: Stack.new(termination_protection: true), options: unattended)
    assert_equal [ { enabled: true } ], client.calls_to(:update_termination_protection).map(&:kwargs)

    @client = nil
    client.stack("blog", termination_protection: true)
    deploy(client, stack: Stack.new(termination_protection: false), options: unattended)
    assert_equal [ { enabled: false } ], client.calls_to(:update_termination_protection).map(&:kwargs)

    @client = nil
    client.stack("blog", termination_protection: true)
    deploy(client, stack: Stack.new(termination_protection: true), options: unattended)
    assert_empty client.calls_to(:update_termination_protection), "nothing is sent when nothing changes"
  end

  def test_a_refused_creation_that_was_protected_can_still_be_removed
    out = D::Fakes::Output.new(approvals: false)

    assert_raises(D::ApprovalRequired) { deploy(client, out, stack: Stack.new(termination_protection: true), options: D::DeployOptions.new) }

    assert_equal [ { enabled: true }, { enabled: false } ], client.calls_to(:update_termination_protection).map(&:kwargs)
    assert_equal "DELETE_COMPLETE", client.stack_record("blog").status
  end

  # --- no-rollback

  def test_no_rollback_is_passed_to_an_update_and_never_to_a_creation
    client.stack("blog")
    deploy(client, options: unattended(no_rollback: true))
    assert_equal true, client.kwargs_of(:execute_change_set).first[:disable_rollback]

    @client = nil
    deploy(client, options: unattended(no_rollback: true))
    assert_equal false, client.kwargs_of(:execute_change_set).first[:disable_rollback], "a creation carries OnStackFailure instead"
  end

  # --- approval is exactly true, whatever an output answers

  def test_only_exactly_true_approves_a_deploy
    client.on(:describe_change_set, described(status: "CREATE_COMPLETE"))
    [ "", "yes", 1, :true, nil ].each do |answer|
      out = D::Fakes::Output.new(approvals: [ false, answer ])

      error = assert_raises(D::ApprovalRequired, answer.inspect) { deploy(client, out, options: D::DeployOptions.new(account: ACCOUNT)) }

      assert_equal 4, D.exit_code_for(error)
      assert_equal "DELETE_COMPLETE", client.stack_record("blog").status
      @client = nil
      client.on(:describe_change_set, described(status: "CREATE_COMPLETE"))
    end
  end

  def test_a_yes_that_is_not_the_boolean_does_not_count
    out = D::Fakes::Output.new(approvals: false)

    assert_raises(D::ApprovalRequired) { deploy(client, out, options: D::DeployOptions.new(yes: "yes", account: ACCOUNT)) }
  end

  # --- the helpers the tests above share

  def client
    @client ||= D::Fakes::CfnClient.new
  end
end
