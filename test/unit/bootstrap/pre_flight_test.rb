# frozen_string_literal: true

# The pre-flight table (architecture section 8, the engine's section 9 states):
# every row, against the engine's fake client and fake object store. The bucket
# is checked before the stack, and the pre-flight never creates anything.

require "test_helper"
require "ruby_cdk/bootstrap"
require "ruby_cdk/deploy/fakes"

class BootstrapPreFlightTest < Minitest::Test
  D = RubyCdk::Deploy
  F = D::Fakes

  ACCOUNT = F::CfnClient::ACCOUNT
  OTHER_ACCOUNT = "999988887777"
  REGION = F::CfnClient::REGION
  TARGET = RubyCdk::Env.new(account: ACCOUNT, region: REGION)
  BUCKET = "ruby-cdk-assets-#{ACCOUNT}-#{REGION}"
  STACK_NAME = "ruby-cdk-bootstrap"

  def test_a_stack_that_is_not_there_and_no_bucket_create
    _client, _store, decided = check

    assert_decision decided, :create, :absent, :absent
  end

  def test_a_review_stack_and_no_bucket_create_again
    _client, _store, decided = check(stack_status: "REVIEW_IN_PROGRESS")

    assert_decision decided, :create, :review, :absent
  end

  def test_a_failed_creation_and_no_bucket_create_after_the_engine_deletes_it
    _client, _store, decided = check(stack_status: "ROLLBACK_COMPLETE")

    assert_decision decided, :create, :rollback_complete, :absent
  end

  def test_a_stable_stack_and_our_bucket_update
    _client, _store, decided = check(stack_status: "CREATE_COMPLETE", bucket_owner: ACCOUNT)

    assert_decision decided, :update, :stable, :mine
  end

  def test_a_stable_stack_and_a_bucket_gone_by_hand_still_updates_with_the_fact_carried
    _client, _store, decided = check(stack_status: "UPDATE_COMPLETE")

    assert_decision decided, :update, :stable, :absent
  end

  def test_a_busy_stack_is_handed_to_the_engine_which_refuses_it
    _client, _store, decided = check(stack_status: "UPDATE_IN_PROGRESS", bucket_owner: ACCOUNT)

    assert_decision decided, :deploy, :busy, :mine
  end

  def test_a_stack_whose_rollback_needs_repair_is_handed_to_the_engine_which_refuses_it
    _client, _store, decided = check(stack_status: "UPDATE_ROLLBACK_FAILED")

    assert_decision decided, :deploy, :rollback_failed, :absent
  end

  # --- the orphan bucket: ours, but no bootstrap stack

  def test_an_orphan_bucket_of_ours_is_refused_with_the_two_ways_out
    _client, _store, error = check(bucket_owner: ACCOUNT)

    assert_instance_of RubyCdk::Bootstrap::OrphanBucket, error
    assert_equal 1, D.exit_code_for(error)
    assert_match(/exists in account #{ACCOUNT}, but the bootstrap stack #{STACK_NAME} does not/, error.message)
    assert_match(/Nothing was created or changed/, error.message)
    assert_match(/the bucket is empty: empty it and delete it in the S3 console/, error.message)
    assert_match(/import the bucket into stack #{STACK_NAME} with CloudFormation\s+resource import/, error.message)
    assert_match(/logical ID AssetsBucket/, error.message)
    assert_equal 2, error.message.scan("run `ruby-cdk bootstrap` again").length, "both ways out end in the command"
  end

  def test_an_orphan_bucket_is_refused_when_the_stack_waits_in_review
    error = check(stack_status: "REVIEW_IN_PROGRESS", bucket_owner: ACCOUNT).last

    assert_instance_of RubyCdk::Bootstrap::OrphanBucket, error
  end

  def test_an_orphan_bucket_is_refused_when_the_first_creation_failed
    error = check(stack_status: "ROLLBACK_COMPLETE", bucket_owner: ACCOUNT).last

    assert_instance_of RubyCdk::Bootstrap::OrphanBucket, error
  end

  # --- the foreign bucket: refused before anything is read or created

  def test_a_foreign_bucket_is_refused_before_the_stack_is_even_read
    _client, _store, error = check(bucket_owner: OTHER_ACCOUNT)

    assert_instance_of RubyCdk::Bootstrap::ForeignBucket, error
    assert_equal 1, D.exit_code_for(error)
    assert_empty _client.operations, "the stack was never read: the bucket stops everything"
    assert_match(/is not owned by account #{ACCOUNT}, which is who the\s+credentials are for/, error.message)
    assert_match(/403 Forbidden/, error.message)
    assert_match(/Bucket names are global/, error.message)
    assert_match(/credentials of account #{ACCOUNT}, the one the stack's env names/, error.message)
  end

  def test_a_foreign_bucket_stops_a_stable_stack_too
    error = check(stack_status: "CREATE_COMPLETE", bucket_owner: OTHER_ACCOUNT).last

    assert_instance_of RubyCdk::Bootstrap::ForeignBucket, error
  end

  def test_ours_is_whatever_account_the_identity_is_for
    client = F::CfnClient.new(identity: D::Identity.new(account: OTHER_ACCOUNT, region: REGION,
      arn: "arn:aws:iam::#{OTHER_ACCOUNT}:user/other"))
    store = F::ObjectStore.new
    store.bucket(BUCKET, owner: ACCOUNT)

    # Our bucket, someone else's credentials: foreign to them, and the message
    # names both accounts.
    error = assert_raises(RubyCdk::Bootstrap::ForeignBucket) do
      RubyCdk::Bootstrap.pre_flight(client:, store:, identity: client.identity, env: TARGET)
    end

    assert_match(/not owned by account #{OTHER_ACCOUNT}/, error.message)
    assert_match(/credentials of account #{ACCOUNT}/, error.message)
    assert_equal OTHER_ACCOUNT, store.calls.first.kwargs[:expected_owner], "the owner named is the identity's"
  end

  def test_the_owner_named_on_the_bucket_check_is_the_identity_s_account
    client, store, = check(bucket_owner: ACCOUNT)

    assert_equal ACCOUNT, store.calls.first.kwargs[:expected_owner]
    assert_equal %i[bucket_state], store.operations
    assert_equal %i[stack_state], client.operations
  end

  private

  # stack_status: registers the bootstrap stack with a CloudFormation status, or
  # nil for an account where it does not exist. bucket_owner: creates the asset
  # bucket owned by that account, or nil for no bucket. Answers
  # [client, store, decision or exception].
  def check(stack_status: nil, bucket_owner: nil)
    client = F::CfnClient.new
    client.stack(STACK_NAME, status: stack_status) if stack_status
    store = F::ObjectStore.new
    store.bucket(BUCKET, owner: bucket_owner) if bucket_owner

    decided = begin
      RubyCdk::Bootstrap.pre_flight(client:, store:, identity: client.identity, env: TARGET)
    rescue RubyCdk::Error => e
      e
    end
    [ client, store, decided ]
  end

  def assert_decision(decided, action, stack_state, bucket_state)
    assert_instance_of RubyCdk::Bootstrap::Decision, decided
    assert_equal action, decided.action
    assert_equal stack_state, decided.stack_state
    assert_equal BUCKET, decided.bucket
    assert_equal bucket_state, decided.bucket_state
  end
end
