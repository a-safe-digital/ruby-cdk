# frozen_string_literal: true

require "test_helper"
require_relative "../../support/deploy_fixtures"

# What the engine does in each of the six stack states (architecture section 9):
# absent and review create, stable updates, busy and rollback_failed are refused,
# and rollback_complete is deleted and created again.
class DeployStackStatesTest < Minitest::Test
  include DeployFixtures
  D = RubyCdk::Deploy
  NAME = D::Deployer::CHANGE_SET_NAME
  STACK_ID = "arn:aws:cloudformation:eu-west-1:111122223333:stack/blog/already-there"

  def request
    requests = client.kwargs_of(:create_change_set)
    assert_equal 1, requests.length, "one change set is created"
    requests.first
  end

  def test_an_absent_stack_gets_a_create_change_set_that_deletes_the_stack_on_failure
    result = deploy(client, options: unattended)

    assert_equal :create, request[:change_set_type]
    assert_equal "DELETE", request[:on_stack_failure]
    assert_equal TEMPLATE, request[:template]
    assert_equal [ "blog", NAME ], client.calls_to(:create_change_set).first.args
    executed = client.kwargs_of(:execute_change_set)
    assert_equal [ { disable_rollback: false, retain_except_on_create: true } ], executed
    assert_equal :deployed, result.outcome
    assert_equal 0, result.exit_code
    assert_equal "CREATE_COMPLETE", client.stack_record("blog").status
    refute_includes client.operations, :delete_change_set, "an absent stack has no earlier change set to remove"
    refute_includes client.operations, :delete_stack
  end

  def test_a_stack_in_review_in_progress_is_created_again_under_its_own_id
    client.stack("blog", status: "REVIEW_IN_PROGRESS", id: STACK_ID)

    result = deploy(client, options: unattended)

    assert_equal :create, request[:change_set_type]
    assert_equal [ [ "blog", NAME ] ], client.calls_to(:delete_change_set).map(&:args), "the change set that was never executed goes first"
    assert_equal [ STACK_ID, client.change_sets.keys.first ], client.calls_to(:execute_change_set).first.args
    assert_equal :deployed, result.outcome
  end

  STABLE = %w[CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE IMPORT_COMPLETE IMPORT_ROLLBACK_COMPLETE].freeze

  STABLE.each do |status|
    define_method("test_#{status.downcase}_is_updated_through_a_change_set") do
      client.stack("blog", status: status, template: "{}")

      result = deploy(client, options: unattended)

      assert_equal :update, request[:change_set_type]
      assert_nil request[:on_stack_failure], "OnStackFailure is for a creation only"
      assert_equal :deployed, result.outcome
      refute_includes client.operations, :delete_stack
    end
  end

  def test_a_busy_stack_is_refused_and_nothing_is_changed
    %w[UPDATE_IN_PROGRESS CREATE_IN_PROGRESS DELETE_IN_PROGRESS UPDATE_ROLLBACK_IN_PROGRESS].each do |status|
      @client = nil
      client.stack("blog", status: status)
      out = D::Fakes::Output.new

      error = assert_raises(D::StackBusy, status) { deploy(client, out, options: unattended) }

      assert_equal 1, D.exit_code_for(error)
      assert_match(/Stack blog is #{status}: an operation is already running/, error.message)
      assert_match(/run the command again/, error.message)
      assert_equal %i[stack_state stack_info], client.operations
    end
  end

  ROLLBACK_COMPLETE = %w[ROLLBACK_COMPLETE ROLLBACK_FAILED].freeze

  ROLLBACK_COMPLETE.each do |status|
    define_method("test_#{status.downcase}_is_deleted_and_created_again") do      client.stack("blog", status: status, id: STACK_ID)
      out = D::Fakes::Output.new

      result = deploy(client, out, options: unattended)

      assert_match(/is in #{status}.*Deleting it, then creating it again/, out.announcements.first)
      operations = client.operations
      assert_equal %i[stack_state stack_info delete_stack stack_state create_change_set], operations.first(5),
        "the deletion is waited for, then the creation starts"
      assert_equal [ STACK_ID ], client.calls_to(:delete_stack).first.args, "it is deleted by its ID"
      assert_equal :create, request[:change_set_type]
      assert_equal :deployed, result.outcome
      assert_equal "CREATE_COMPLETE", client.stack_record("blog").status
    end
  end

  def test_a_failed_creation_whose_deletion_does_not_finish_is_left_alone
    client.stack("blog", status: "ROLLBACK_COMPLETE", id: STACK_ID)
    client.on(:delete_stack, ->(_call) { })
    client.on(:stack_state, :rollback_complete, :busy, :rollback_failed)

    error = assert_raises(D::StackNeedsRepair) { deploy(client, options: unattended) }

    assert_equal 1, D.exit_code_for(error)
    assert_match(/could not be deleted: it is in ROLLBACK_COMPLETE/, error.message)
    refute_includes client.operations, :create_change_set, "nothing is created on top of a stack that is still there"
  end

  ROLLBACK_FAILED = %w[UPDATE_ROLLBACK_FAILED CREATE_FAILED UPDATE_FAILED DELETE_FAILED].freeze

  ROLLBACK_FAILED.each do |status|
    define_method("test_#{status.downcase}_is_refused_with_the_way_out") do
      client.stack("blog", status: status)

      error = assert_raises(D::StackNeedsRepair, status) { deploy(client, options: unattended) }

      assert_equal 1, D.exit_code_for(error)
      assert_match(/Stack blog is in #{status} and has to be repaired/, error.message)
      assert_match(/run the command again/, error.message)
      assert_equal %i[stack_state stack_info], client.operations
    end
  end

  # --- the helpers the tests above share

  def client
    @client ||= D::Fakes::CfnClient.new
  end
end
