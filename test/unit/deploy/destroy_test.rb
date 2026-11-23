# frozen_string_literal: true

require "test_helper"
require_relative "../../support/deploy_fixtures"

# Destroy (architecture section 9): what is retained is printed, a protected
# stack is refused, the stack name has to be typed unless --yes, and the
# deletion is followed to its end.
class DeployDestroyTest < Minitest::Test
  include DeployFixtures
  D = RubyCdk::Deploy

  STACK_ID = "arn:aws:cloudformation:eu-west-1:111122223333:stack/blog/kept-id"

  def with_retained_resources
    client.stack("blog", id: STACK_ID, template: template(resources: {
      "Queue" => { "Type" => "AWS::SQS::Queue", "DeletionPolicy" => "Delete" },
      "Data" => { "Type" => "AWS::DynamoDB::Table", "DeletionPolicy" => "RetainExceptOnCreate" },
      "Db" => { "Type" => "AWS::RDS::DBInstance", "DeletionPolicy" => "Snapshot" },
      "Kept" => { "Type" => "AWS::S3::Bucket", "DeletionPolicy" => "Retain" },
      "Table" => { "Type" => "AWS::DynamoDB::Table" }
    }))
  end

  def test_a_stack_that_does_not_exist_has_nothing_to_destroy
    out = D::Fakes::Output.new

    result = destroy(client, out, options: unattended)

    assert_equal :no_changes, result.outcome
    assert_equal 0, result.exit_code
    assert_equal %i[stack_state], client.operations
    assert out.announcements.any? { |text| text.include?("does not exist: nothing to destroy") }
  end

  def test_the_resources_that_will_be_kept_are_listed_and_nothing_else
    with_retained_resources
    out = D::Fakes::Output.new(confirmations: "blog")

    destroy(client, out, options: D::DeployOptions.new)

    kept = out.shown_retained
    assert_equal %w[Data Db Kept], kept.map(&:logical_id)
    assert_equal %w[RetainExceptOnCreate Snapshot Retain], kept.map(&:deletion_policy)
    assert_equal "AWS::RDS::DBInstance", kept[1].resource_type
    assert_equal %i[target retained confirm], out.calls.map(&:operation), "it is said after the target, before anything is asked"
  end

  def test_a_stack_with_nothing_to_keep_says_so_with_an_empty_list
    client.stack("blog", template: TEMPLATE)
    out = D::Fakes::Output.new(confirmations: "blog")

    destroy(client, out, options: D::DeployOptions.new)

    assert_equal [], out.shown_retained
    assert_equal 1, out.said(:retained).length
  end

  def test_a_deployed_template_that_is_not_json_says_that_nothing_could_be_listed
    client.stack("blog", template: "Resources:\n  Data:\n    Type: AWS::DynamoDB::Table\n    DeletionPolicy: Retain\n")
    out = D::Fakes::Output.new(confirmations: "blog")

    destroy(client, out, options: D::DeployOptions.new)

    assert_equal [], out.shown_retained
    assert out.announcements.any? { |text| text.include?("could not be listed") }
  end

  def test_a_protected_stack_is_refused_with_the_way_to_turn_it_off
    client.stack("blog", termination_protection: true)
    out = D::Fakes::Output.new(confirmations: "blog")

    error = assert_raises(D::DestroyRefused) { destroy(client, out, options: unattended) }

    assert_equal 1, D.exit_code_for(error)
    assert_match(/has termination protection, so destroy refuses to delete it/, error.message)
    assert_match(/termination_protection: false/, error.message)
    assert_match(/Edit termination protection/, error.message)
    assert_match(/run `ruby-cdk destroy blog` again/, error.message)
    refute_includes client.operations, :delete_stack
    assert_equal "CREATE_COMPLETE", client.stack_record("blog").status
  end

  def test_a_busy_stack_is_refused
    client.stack("blog", status: "DELETE_IN_PROGRESS")

    error = assert_raises(D::StackBusy) { destroy(client, options: unattended) }

    assert_equal 1, D.exit_code_for(error)
    assert_match(/is DELETE_IN_PROGRESS/, error.message)
    refute_includes client.operations, :delete_stack
  end

  def test_the_stack_name_has_to_be_typed_and_nothing_is_deleted_otherwise
    client.stack("blog", template: TEMPLATE)
    out = D::Fakes::Output.new(confirmations: [ "other", "", "blog ", nil, 1 ])

    5.times do
      error = assert_raises(D::ApprovalRequired) { destroy(client, out, options: D::DeployOptions.new) }

      assert_equal 4, D.exit_code_for(error)
      assert_match(/name of stack blog was not typed, so nothing was deleted/, error.message)
    end

    assert_equal [ "blog" ] * 5, out.confirmations, "the stack is named each time"
    refute_includes client.operations, :delete_stack, "only exactly true approves a deletion"
  end

  def test_once_the_name_is_typed_the_stack_is_deleted_and_followed_to_the_end
    client.stack("blog", id: STACK_ID, template: TEMPLATE)
    client.emit("blog", "DELETE_IN_PROGRESS")
    client.emit("blog", "DELETE_COMPLETE")
    out = D::Fakes::Output.new(confirmations: "blog")

    result = destroy(client, out, options: D::DeployOptions.new)

    assert_equal :deployed, result.outcome
    assert_equal 0, result.exit_code
    assert_equal STACK_ID, result.stack_id
    assert_equal [ STACK_ID ], client.calls_to(:delete_stack).first.args, "it is deleted by its ID"
    assert_equal "DELETE_COMPLETE", client.stack_record("blog").status
    assert_equal %w[DELETE_IN_PROGRESS DELETE_COMPLETE], out.shown_events.map(&:resource_status)
  end

  def test_yes_skips_the_confirmation
    client.stack("blog", template: TEMPLATE)
    out = D::Fakes::Output.new

    result = destroy(client, out, options: unattended)

    assert_equal :deployed, result.outcome
    assert_empty out.confirmations
    assert_equal 1, out.said(:retained).length, "what will be kept is still said"
  end

  def test_a_stack_whose_creation_failed_or_was_never_executed_can_be_destroyed
    %w[ROLLBACK_COMPLETE REVIEW_IN_PROGRESS UPDATE_ROLLBACK_FAILED].each do |status|
      @client = nil
      client.stack("blog", status: status)

      result = destroy(client, options: unattended)

      assert_equal :deployed, result.outcome, status
      assert_equal "DELETE_COMPLETE", client.stack_record("blog").status
    end
  end

  def test_a_deletion_that_fails_is_a_result_with_exit_code_5_and_the_way_to_retry
    client.stack("blog", template: TEMPLATE)
    client.on(:delete_stack, lambda { |_call|
      client.stack_record("blog").status = "DELETE_FAILED"
      client.emit("blog", "DELETE_FAILED", logical_id: "Bucket", resource_type: "AWS::S3::Bucket", status_reason: "The bucket is not empty")
    })
    out = D::Fakes::Output.new

    result = destroy(client, out, options: unattended)

    assert_equal :failed, result.outcome
    assert_equal 5, result.exit_code
    text = out.failures.first
    assert_match(/Stack blog could not be deleted: it ended in DELETE_FAILED/, text)
    assert_match(/Bucket \(AWS::S3::Bucket\) DELETE_FAILED: The bucket is not empty/, text)
    assert_match(/Retry delete/, text)
  end

  def test_a_deletion_that_does_not_finish_is_given_up_on
    client.stack("blog", template: TEMPLATE)
    client.on(:delete_stack, lambda { |_call| client.stack_record("blog").status = "DELETE_IN_PROGRESS" })
    impatient = D::Poller.new(interval: 1, factor: 1, max_interval: 1, limit: 2, sleep: ->(_seconds) { })

    error = assert_raises(D::WaitTimedOut) { destroy(client, options: unattended, operation_poller: impatient) }

    assert_equal 1, D.exit_code_for(error)
    assert_match(/the operation on stack blog did not finish/, error.message)
  end

  def test_a_deletion_that_never_started_is_a_failure
    client.stack("blog", template: TEMPLATE)
    client.on(:delete_stack, lambda { |_call| client.stack_record("blog").status = "REVIEW_IN_PROGRESS" })
    out = D::Fakes::Output.new

    result = destroy(client, out, options: unattended)

    assert_equal :failed, result.outcome
    assert_equal 5, result.exit_code
    assert_match(/still in REVIEW_IN_PROGRESS: the deletion did not start/, out.failures.first)
  end

  def test_a_deletion_aws_refuses_to_start_is_not_swallowed
    client.stack("blog", template: TEMPLATE)
    client.on(:delete_stack, RubyCdk::PreconditionError.new("AccessDenied: no cloudformation:DeleteStack"))
    out = D::Fakes::Output.new

    error = assert_raises(RubyCdk::PreconditionError) { destroy(client, out, options: unattended) }

    assert_equal "AccessDenied: no cloudformation:DeleteStack", error.message
    assert_equal 1, D.exit_code_for(error)
  end

  # --- the helpers the tests above share

  def client
    @client ||= D::Fakes::CfnClient.new
  end
end
