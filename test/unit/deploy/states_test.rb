# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/deploy"

# The six stack states, exactly as the table of architecture section 9 places
# every CloudFormation status. The statuses are the ones the SDK documents for
# DescribeStacks (aws-sdk-cloudformation 1.174.0), so that the test says of
# each of them where it goes, or that it is refused.
class DeployStatesTest < Minitest::Test
  Deploy = RubyCdk::Deploy

  TABLE = {
    absent: %w[DELETE_COMPLETE],
    review: %w[REVIEW_IN_PROGRESS],
    stable: %w[CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE IMPORT_COMPLETE IMPORT_ROLLBACK_COMPLETE],
    rollback_complete: %w[ROLLBACK_COMPLETE ROLLBACK_FAILED],
    rollback_failed: %w[UPDATE_ROLLBACK_FAILED CREATE_FAILED UPDATE_FAILED DELETE_FAILED],
    busy: %w[
      CREATE_IN_PROGRESS ROLLBACK_IN_PROGRESS DELETE_IN_PROGRESS UPDATE_IN_PROGRESS UPDATE_COMPLETE_CLEANUP_IN_PROGRESS
      UPDATE_ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS IMPORT_IN_PROGRESS
      IMPORT_ROLLBACK_IN_PROGRESS
    ]
  }.freeze

  # Every status DescribeStacks documents, once.
  DOCUMENTED = %w[
    CREATE_IN_PROGRESS CREATE_FAILED CREATE_COMPLETE ROLLBACK_IN_PROGRESS ROLLBACK_FAILED ROLLBACK_COMPLETE
    DELETE_IN_PROGRESS DELETE_FAILED DELETE_COMPLETE UPDATE_IN_PROGRESS UPDATE_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_COMPLETE
    UPDATE_FAILED UPDATE_ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_FAILED UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS
    UPDATE_ROLLBACK_COMPLETE REVIEW_IN_PROGRESS IMPORT_IN_PROGRESS IMPORT_COMPLETE IMPORT_ROLLBACK_IN_PROGRESS
    IMPORT_ROLLBACK_FAILED IMPORT_ROLLBACK_COMPLETE
  ].freeze

  def test_every_status_in_the_table_goes_where_the_table_says
    TABLE.each do |state, statuses|
      statuses.each { |status| assert_equal state, Deploy::States.classify(status), status }
    end
  end

  def test_the_table_covers_every_status_the_sdk_documents_but_one
    placed = TABLE.values.flatten
    assert_equal %w[IMPORT_ROLLBACK_FAILED], DOCUMENTED - placed
    assert_equal [], placed - DOCUMENTED
  end

  def test_a_stack_that_does_not_exist_is_absent
    assert_equal :absent, Deploy::States.classify(nil)
    assert_equal :absent, Deploy::StackStatus.state(nil)
  end

  def test_an_unknown_status_is_an_error_never_a_guess
    error = assert_raises(Deploy::UnknownStackStatus) { Deploy::States.classify("UPDATE_ROLLBACK_FAILED_COMPLETELY") }
    assert_match(/UPDATE_ROLLBACK_FAILED_COMPLETELY/, error.message)
    assert_match(/Nothing was changed/, error.message)
    assert_equal 1, Deploy.exit_code_for(error)
    assert_nil Deploy::StackStatus.state("UPDATE_ROLLBACK_FAILED_COMPLETELY")
  end

  # A status the table does not place, although the SDK lists it: the table is
  # binding, and this records the gap rather than papering over it.
  def test_import_rollback_failed_is_refused_as_unknown
    assert_raises(Deploy::UnknownStackStatus) { Deploy::States.classify("IMPORT_ROLLBACK_FAILED") }
  end

  def test_anything_that_ends_in_in_progress_is_busy_even_one_nobody_has_seen
    assert_equal :busy, Deploy::States.classify("SOMETHING_NEW_IN_PROGRESS")
  end

  def test_a_status_is_never_matched_loosely
    assert_raises(Deploy::UnknownStackStatus) { Deploy::States.classify("create_complete") }
    assert_raises(Deploy::UnknownStackStatus) { Deploy::States.classify(" CREATE_COMPLETE ") }
    assert_raises(Deploy::UnknownStackStatus) { Deploy::States.classify(:create_complete) }
    assert_raises(Deploy::UnknownStackStatus) { Deploy::States.classify("") }
  end

  def test_the_six_states_are_the_ones_the_port_answers
    assert_equal %i[absent review stable rollback_complete rollback_failed busy], Deploy::STACK_STATES
    assert_equal Deploy::STACK_STATES.sort, TABLE.keys.sort
  end

  def test_every_rollback_failed_status_has_a_way_out
    TABLE[:rollback_failed].each do |status|
      path = Deploy::States.repair_path(status)
      assert path, status
      assert_match(/run the command again/, path)
      assert_match(%r{https://docs\.aws\.amazon\.com/AWSCloudFormation/}, path)
    end
  end

  def test_the_way_out_names_the_console_path_aws_documents
    assert_match(/Continue update rollback/, Deploy::States.repair_path("UPDATE_ROLLBACK_FAILED"))
    assert_match(/Stack actions/, Deploy::States.repair_path("UPDATE_ROLLBACK_FAILED"))
    assert_match(/Roll back/, Deploy::States.repair_path("CREATE_FAILED"))
    assert_match(/the rollback deletes it/, Deploy::States.repair_path("CREATE_FAILED"))
    assert_match(/Retry delete/, Deploy::States.repair_path("DELETE_FAILED"))
  end

  def test_a_status_that_needs_no_repair_has_no_way_out
    assert_nil Deploy::States.repair_path("CREATE_COMPLETE")
    assert_nil Deploy::States.repair_path("ROLLBACK_COMPLETE")
    assert_nil Deploy::States.repair_path(nil)
  end
end
