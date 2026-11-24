# frozen_string_literal: true

# The whole of `ruby-cdk bootstrap`, end to end in process (architecture
# section 8): build, pre-flight, synthesize, deploy through the engine —
# everything against the engine's fakes, and the result is the engine's
# DeployResult. Nothing is published: the bootstrap stack has no assets.

require "test_helper"
require "json"
require "ruby_cdk/bootstrap"
require "ruby_cdk/deploy/fakes"

class BootstrapRunTest < Minitest::Test
  D = RubyCdk::Deploy
  F = D::Fakes

  ACCOUNT = F::CfnClient::ACCOUNT
  REGION = F::CfnClient::REGION
  TARGET = RubyCdk::Env.new(account: ACCOUNT, region: REGION)
  BUCKET = "ruby-cdk-assets-#{ACCOUNT}-#{REGION}"
  STACK_NAME = "ruby-cdk-bootstrap"

  # What the run hands to the engine: only cfn and store are read.
  Clients = Struct.new(:cfn, :store)

  def setup
    RubyCdk::App.reset!
  end

  def teardown
    RubyCdk::App.reset!
  end

  def test_a_first_bootstrap_deploys_the_stack_and_publishes_nothing
    out = F::Output.new(approvals: true)

    result = run_bootstrap(output: out)

    assert_instance_of D::DeployResult, result
    assert_equal :deployed, result.outcome
    assert_equal 0, result.exit_code
    assert_equal STACK_NAME, result.stack_name

    change_set = client.change_sets.values.first
    assert_equal :create, change_set.type
    assert_equal "DELETE", change_set.on_stack_failure
    assert_equal [ { key: "ruby-cdk", value: RubyCdk::VERSION } ], change_set.tags
    body = JSON.parse(change_set.template)
    assert_equal BUCKET, body.dig("Resources", "AssetsBucket", "Properties", "BucketName")

    assert_equal %i[bucket_state], store.operations, "no assets, so no upload and no owner check beyond the one"
    assert out.announcements.any? { |text| text.include?("preparing a CloudFormation change set") }
  end

  def test_the_same_bootstrap_again_is_skipped_by_the_engine
    prepare_stable_stack(template: bootstrap_bytes, tags: [ { key: "ruby-cdk", value: RubyCdk::VERSION } ])
    store.bucket(BUCKET, owner: ACCOUNT)

    result = run_bootstrap

    assert_equal :no_changes, result.outcome
    assert_equal 0, result.exit_code
    assert_empty client.change_sets.values, "the engine's idempotency: nothing to deploy"
  end

  def test_a_stable_stack_with_an_empty_bucket_updates
    prepare_stable_stack
    store.bucket(BUCKET, owner: ACCOUNT)

    result = run_bootstrap(output: F::Output.new(approvals: true))

    assert_equal :deployed, result.outcome
    assert_equal :update, client.change_sets.values.first.type
  end

  def test_a_stable_stack_whose_bucket_is_gone_is_announced_before_the_deploy
    prepare_stable_stack
    out = F::Output.new(approvals: true)

    run_bootstrap(output: out)

    note = out.announcements.find { |text| text.include?("#{BUCKET} does not exist") }
    refute_nil note, "the announce comes before the deploy, so nobody mistakes the result"
    assert_match(/does not recreate a bucket the template already names/, note)
    assert_match(%r{`ruby-cdk destroy #{STACK_NAME}`}, note)
  end

  def test_an_orphan_bucket_stops_the_run_before_anything_is_created
    orphan_client = F::CfnClient.new
    orphan_client.stack(STACK_NAME, status: "DELETE_COMPLETE")
    orphan_store = F::ObjectStore.new
    orphan_store.bucket(BUCKET, owner: ACCOUNT)

    error = assert_raises(RubyCdk::Bootstrap::OrphanBucket) { run_bootstrap(client: orphan_client, store: orphan_store) }

    assert_match(/Two ways out/, error.message)
    assert_empty orphan_client.change_sets.values, "nothing was created"
  end

  def test_approval_is_asked_when_the_command_did_not_say_yes
    out = F::Output.new(approvals: false)

    error = assert_raises(D::ApprovalRequired) { run_bootstrap(output: out) }

    assert_equal 4, D.exit_code_for(error)
    assert out.questions.any? { |question| question.include?("Deploy these changes to stack #{STACK_NAME}") }
  end

  def test_yes_from_the_command_deploys_without_asking
    out = F::Output.new

    result = run_bootstrap(output: out, options: D::DeployOptions.new(yes: true))

    assert_equal :deployed, result.outcome
    assert_empty out.questions, "--yes was given, so nobody was asked"
  end

  def test_the_identity_is_asked_of_the_client_before_the_bucket
    run_bootstrap

    assert_equal %i[resolve_identity], client.operations.first(1)
    assert_equal %i[bucket_state], store.operations.first(1)
    assert out.targets.last, "the engine showed the target"
  end

  private

  attr_reader :client, :store, :out

  # Runs the command against the fakes that were prepared (prepare_stable_stack),
  # or against fresh ones.
  def run_bootstrap(client: nil, store: nil, output: nil, options: nil)
    @client = client || @client || F::CfnClient.new
    @store = store || @store || F::ObjectStore.new
    @out = output || @out || F::Output.new(approvals: true)
    app = RubyCdk::App.new(env: TARGET)

    RubyCdk::Bootstrap.run(app:, clients: Clients.new(@client, @store), output: @out, options:)
  end

  def prepare_stable_stack(template: nil, tags: [])
    @client = F::CfnClient.new
    @store = F::ObjectStore.new
    @out = F::Output.new(approvals: true)
    @client.stack(STACK_NAME, status: "CREATE_COMPLETE", template:, tags:)
  end

  # The exact bytes the engine would compare against, from a throwaway App.
  def bootstrap_bytes
    app = RubyCdk::App.new(env: TARGET)
    RubyCdk::Synth.synthesize(RubyCdk::Bootstrap.stack(app:)).bytes
  end
end
