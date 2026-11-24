# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/@aws-cdk/toolkit-lib/test/api/deployments/deploy-stack.test.ts,
#            in aws/aws-cdk-cli
#   Commit:  eca1b73d682d7763955bec30ab5dd52bbc4327b6 (main, read on 2026-11-24)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin holds 91 test declarations and 5 test.each tables with 26 rows
# between them: 117 cases. Each ported one keeps its name, as a comment above
# the test, and what it expects. The scenarios there run deployStack() against
# a mock CloudFormation client; here they run Deployer#deploy against the
# scripted fake of lib/ruby_cdk/deploy/fakes.rb, through the harness of
# support/cdk_deploy.rb (the stack artifact carries target_template, the stack
# CloudFormation holds is given start_template, and given_stack_exists,
# given_template_is and given_no_updates_are_to_be_performed play the origin's
# given* functions).
#
# Changed, with nothing else in a scenario, an input or an outcome:
#   - jest's mockClient answers each command in sequence; the fake answers per
#     operation with on(), and what the engine sent is asserted with calls_to
#     and kwargs_of. toHaveReceivedCommandWith(X, Y) is an assert on
#     kwargs_of(:x).first; rejects.toThrow is assert_raises.
#   - The origin's harness answers its approval questions by itself; an
#     unattended deploy of a stack without env needs --account here (D-026),
#     so every deploy carries yes: true and the account (unattended).
#   - The origin checks the SDK command's flags: "not received with
#     DisableRollback: true" and "do not pass the flag". The engine passes
#     disable_rollback explicitly on every execution and false means enabled;
#     the ports assert the value.
#   - Messages are matched by what they name, not word for word: the engine's
#     rejection and failure texts are its own (it says "CloudFormation rejected
#     the change set" where the origin throws "Early validation failed for
#     change set").
#   - usePreviousParameters has no counterpart: the engine sends the resolved
#     parameter values in full (lib/ruby_cdk/deploy/parameters.rb) and its
#     skip rule compares exactly those. Where a given* fixture in the origin
#     relies on the flag, the fixture here deploys exactly what the engine
#     would send.
#
# Ported with an expectation changed, where this tool differs by design, said
# next to the expectation:
#   - deploy is not skipped if parameters are different: the origin also
#     expects UsePreviousValue entries for the parameters it reuses; the
#     engine leaves the parameters it does not name out of the request
#     (lib/ruby_cdk/deploy/parameters.rb), and CloudFormation keeps their
#     deployed values.
#   - deploy is not skipped if stack is in a _FAILED state: the CDK deploys
#     onto DELETE_FAILED (it expects CreateChangeSet and ExecuteChangeSet);
#     the six-state table of architecture section 9 refuses every status that
#     maps to :rollback_failed, with the way to repair it, before anything is
#     created.
#   - no-rollback and replacement is disadvised, first row (UPDATE_FAILED, no
#     rollback, no replacement): the CDK fix-forwards onto the failed stack
#     with --no-rollback; the engine refuses the state (section 9, as above).
#
# FINDING, left failing: no-rollback and replacement is disadvised, last row
# (UPDATE_COMPLETE, no rollback, replacement). The CDK refuses to execute a
# change set that replaces a resource when rollback is disabled, and answers
# 'replacement-requires-rollback' without executing anything
# (lib/api/deployments/deploy-stack.ts, checkAndExecuteChangeSet: `if
# (!rollbackEnabled && replacement) return { type:
# 'replacement-requires-rollback' }`). This engine has no replacement check:
# it executes the change set with disable_rollback and answers :deployed. The
# engine is wrong or the contract is; nothing in section 21 records the
# difference.
#
# Not ported, with the reason:
#
#   A later wave builds what these need (outcome 3):
#   - hotswap: calls tryHotswapDeployment() if deploymentMethod is hotswap
#     with fallback; calls tryHotswapDeployment() if deploymentMethod is
#     hotswap-only; correctly passes CFN parameters when hotswapping;
#     correctly passes SSM parameters when hotswapping; prints revert-drift
#     recommendation on successful hotswap deployment; hotswap template cache >
#     writeHotswapTemplateCache is called on a successful hotswap deployment;
#     > invalidateHotswapTemplateCache is called on a non-hotswap deployment;
#     > invalidateHotswapTemplateCache is called on a hotswap fallback
#     deployment; does not call tryHotswapDeployment() if deploymentMethod is
#     not hotswap; rollback still defaults to enabled even if 'hotswap' is
#     enabled; deploy is not skipped if we are deploying and there is a change
#     from the last hotswap deployment; deploy is skipped if no changes
#     detected between current and previous hotswap templates.
#   - the template sent by S3 URL, a Wave 3 asset: use S3 url for stack
#     deployment if present in Stack Artifact; use REST API S3 url with
#     substituted placeholders if manifest url starts with s3://.
#
#   A difference by design (outcome 4):
#   - express mode, which this tool does not have: passes EXPRESS mode in
#     DeploymentConfig when creating a new stack via change-set; passes
#     STANDARD mode in DeploymentConfig by default; passes EXPRESS mode in
#     DeploymentConfig when creating a stack via method=direct; passes EXPRESS
#     mode in DeploymentConfig when updating an existing stack via
#     method=direct; express mode with rollback=true passes DisableRollback:
#     false; express mode without rollback does not pass DisableRollback;
#     hotswap fallback uses standard mode; hotswap fallback with method=direct
#     uses standard mode; express mode and replacement from a stable state
#     (test.each, 2 cases); express mode with a replacement submits nothing
#     for execution; failed express stack does not route to rollback
#     (test.each, 4 cases); the 12-case matrix from '1: UF, stack E, req E,
#     rollback unset, replacement -> ExpressStackFailPaused' to '12: UC, stack
#     S, req S, rollback unset, replacement -> deploys'.
#   - the direct deployment method (every deploy is a change set, D-010): call
#     CreateStack when method=direct and the stack doesnt exist yet; call
#     UpdateStack when method=direct and the stack exists already;
#     method=direct and no updates to be performed.
#   - the execute-change-set deployment method (the engine creates its own
#     change set and executes it; there is no deploy of an existing change
#     set): execute-change-set describes and executes an existing change set;
#     execute-change-set throws if change set is not ready; execute-change-set
#     throws if change set failed; execute-change-set deployment method >
#     executes an existing change set without creating a new one; > reports
#     the diagnosis when change set failed to create; > throws when change set
#     is in CREATE_PENDING status; > throws without reason when status reason
#     is absent; > returns replacement-requires-rollback when change set has
#     replacement and rollback is disabled; > returns
#     replacement-requires-rollback when the description silently leaves the
#     replacement out (#2036); > is never skipped by canSkipDeploy; > '17: UC,
#     stack S, existing standard change set with a replacement, req E,
#     rollback unset -> deploys'.
#   - the internal two-phase prepare (willExecuteChangeSet; the engine has one
#     deploy call): deploy is skipped if template did not change and the
#     caller will execute the change set afterwards; does not announce the
#     change set if the caller will execute it afterwards.
#   - userAgentMetadata as User-Agent tokens: the engine's port carries no
#     user agent.
#   - --previous-parameters (UsePreviousValue), which the engine has no flag
#     for: reuse previous parameters if requested. The difference is not in
#     section 21; it is reported.
#   - notificationArns, which neither DeployOptions nor the port carries:
#     deploy is skipped if notificationArns are the same; deploy is not
#     skipped if notificationArns are different. Not in section 21; reported.
#   - rollbackConfiguration (rollback triggers and monitoring time), which
#     neither DeployOptions nor the port carries: rollback configuration is
#     passed through to CloudFormation; deploy is skipped if rollback
#     configuration is the same; deploy is not skipped if rollback
#     configuration is different. Not in section 21; reported.
#   - the #2036 re-describe without property values (the engine describes the
#     change set once): describes the change set again without property values
#     when it would hide a template difference (#2036). Not in section 21;
#     reported.
#   - import existing resources (no ImportExistingResources in the port):
#     import-existing-resources > is disabled by default; > is added to the
#     CreateChangeSetCommandInput; > enhances error message with construct
#     paths when changeset fails; > falls back to logical ID when no construct
#     path metadata exists. Not in section 21; reported.
#   - --revert-drift: revert-drift > is disabled by default; > is added to the
#     CreateChangeSetCommandInput.
#   - nested stacks (docs/07-testing.md section 12): passes IncludeNestedStacks
#     to get nested stack error reporting; does not pass IncludeNestedStacks
#     for import changesets.
#   - assertIsSuccessfulDeployStackResult does what it says: a guard over the
#     CDK's own result types, which the engine has no equivalent of.
#
# Parity: 117 cases in the origin; 40 ported; 77 not ported; 36 tests.

require "test_helper"
require "support/deploy_fixtures"
require "support/cdk_deploy"

class CdkCliDeployStackTest < Minitest::Test
  include CdkDeploy
  D = RubyCdk::Deploy

  def client
    @client ||= D::Fakes::CfnClient.new
  end

  # The origin deploys FAKE_STACK, named withouterrors (cdk_stack); the
  # fixture's default stack is named blog, so every deploy here that does not
  # name one deploys the origin's.
  def deploy(client, output = D::Fakes::Output.new, **options)
    options[:stack] ||= cdk_stack
    super(client, output, **options)
  end

  # test('rollback defaults to enabled if deploymentMethod is not hotswap')
  def test_rollback_defaults_to_enabled_if_the_deployment_method_is_not_hotswap
    result = deploy(client, body: target_template, options: unattended)

    assert_equal :deployed, result.outcome
    executed = client.kwargs_of(:execute_change_set)
    assert_equal 1, executed.length
    assert_equal false, executed.first[:disable_rollback], "rollback is enabled: the flag is not set to true"
  end

  # test('do deploy executable change set with 0 changes')
  #
  # The origin's fake computes the changes of the created change set from the
  # template diff (fake-cloudformation.ts), so a create on an absent stack
  # carries one Add; what the case pins is that an executable change set is
  # executed, whatever it lists.
  def test_do_deploy_executable_change_set_with_0_changes
    result = deploy(client, body: target_template, options: unattended)

    assert_equal :deployed, result.outcome
    assert_equal 1, client.calls_to(:execute_change_set).length
  end

  # test('correctly passes CFN parameters, ignoring ones with empty values')
  def test_correctly_passes_cfn_parameters_ignoring_ones_with_empty_values
    deploy(client, body: target_template,
      options: unattended(parameters: { "A" => "A-value", "B" => "B=value", "C" => nil, "D" => "" }))

    request = client.kwargs_of(:create_change_set).first
    assert_equal [
      { parameter_key: "A", parameter_value: "A-value" },
      { parameter_key: "B", parameter_value: "B=value" }
    ], request[:parameters], "the empty values are left out"
    assert_equal target_template, request[:template], "the template is sent as the body"
  end

  # test('do not reuse previous parameters if not requested')
  def test_do_not_reuse_previous_parameters_if_not_requested
    given_stack_exists(client, name: "withparameters", template: parameters_template)

    deploy(client, stack: cdk_stack(name: "withparameters"), body: parameters_template,
      options: unattended(parameters: { "HasValue" => "SomeValue", "OtherParameter" => "SomeValue" }))

    request = client.kwargs_of(:create_change_set).first
    assert_equal :update, request[:change_set_type]
    assert_equal [
      { parameter_key: "HasValue", parameter_value: "SomeValue" },
      { parameter_key: "OtherParameter", parameter_value: "SomeValue" }
    ], request[:parameters]
  end

  # test('throw exception if not enough parameters supplied')
  def test_throw_exception_if_not_enough_parameters_supplied
    given_stack_exists(client, name: "withparameters", template: parameters_template)

    error = assert_raises(D::ParametersMissing) do
      deploy(client, stack: cdk_stack(name: "withparameters"), body: parameters_template,
        options: unattended(parameters: { "OtherParameter" => "SomeValue" }))
    end

    assert_match(/missing a value: HasValue/, error.message)
    assert_empty client.calls_to(:create_change_set), "nothing is asked of CloudFormation"
  end

  # test('deploy is skipped if template did not change')
  def test_deploy_is_skipped_if_template_did_not_change
    given_no_updates_are_to_be_performed(client)

    result = deploy(client, body: target_template, options: unattended)

    assert_equal :no_changes, result.outcome
    assert_empty client.calls_to(:create_change_set)
    assert_empty client.calls_to(:execute_change_set)
  end

  # test('deploy is skipped if parameters are the same')
  #
  # The origin reaches the skip with --previous-parameters over values deployed
  # long ago; this engine sends the resolved values in full and compares those,
  # so the fixture here deploys exactly what the engine would send (HasDefault
  # takes the template default).
  def test_deploy_is_skipped_if_parameters_are_the_same
    given_stack_exists(client, name: "withparameters", template: parameters_template,
      parameters: { "HasValue" => "TheValue", "HasDefault" => "TheDefault", "OtherParameter" => "OtherParameter" })

    result = deploy(client, stack: cdk_stack(name: "withparameters"), body: parameters_template,
      options: unattended(parameters: { "HasValue" => "TheValue", "OtherParameter" => "OtherParameter" }))

    assert_equal :no_changes, result.outcome
    assert_empty client.calls_to(:create_change_set)
  end

  # test('deploy is not skipped if parameters are different')
  #
  # Changed expectation: the origin also expects UsePreviousValue entries for
  # HasDefault and OtherParameter; this engine leaves the parameters it does
  # not name out of the request (lib/ruby_cdk/deploy/parameters.rb), and
  # CloudFormation keeps their deployed values. There is no
  # --previous-parameters flag here.
  def test_deploy_is_not_skipped_if_parameters_are_different
    given_stack_exists(client, name: "withparameters", template: parameters_template,
      parameters: { "HasValue" => "TheValue", "HasDefault" => "TheDefault", "OtherParameter" => "OtherParameter" })

    deploy(client, stack: cdk_stack(name: "withparameters"), body: parameters_template,
      options: unattended(parameters: { "HasValue" => "NewValue", "OtherParameter" => "OtherParameter" }))

    request = client.kwargs_of(:create_change_set).first
    assert_equal :update, request[:change_set_type]
    assert_equal [
      { parameter_key: "HasValue", parameter_value: "NewValue" },
      { parameter_key: "OtherParameter", parameter_value: "OtherParameter" }
    ], request[:parameters]
  end

  # test('if existing stack failed to create, it is deleted and recreated')
  def test_if_existing_stack_failed_to_create_it_is_deleted_and_recreated
    given_stack_exists(client, status: "ROLLBACK_COMPLETE")

    result = deploy(client, body: target_template, options: unattended)

    assert_equal :deployed, result.outcome
    assert_equal 1, client.calls_to(:delete_stack).length, "the failed creation is deleted"
    assert_equal :create, client.kwargs_of(:create_change_set).first[:change_set_type], "and created again"
  end

  # test('if existing stack failed to create, it is deleted and recreated even if the template did not change')
  def test_if_existing_stack_failed_to_create_it_is_deleted_and_recreated_even_if_the_template_did_not_change
    given_stack_exists(client, status: "ROLLBACK_COMPLETE")
    given_template_is(client, target_template)

    result = deploy(client, body: target_template, options: unattended)

    assert_equal :deployed, result.outcome
    assert_equal 1, client.calls_to(:delete_stack).length
    assert_equal :create, client.kwargs_of(:create_change_set).first[:change_set_type]
  end

  # test('deploy is not skipped if template did not change and --no-execute is given')
  def test_deploy_is_not_skipped_if_template_did_not_change_and_no_execute_is_given
    given_no_updates_are_to_be_performed(client)

    result = deploy(client, body: target_template, options: unattended(no_execute: true))

    assert_equal 1, client.calls_to(:create_change_set).length
    assert_empty client.calls_to(:execute_change_set)
    assert_equal :not_executed, result.outcome
  end

  # test('deploy not skipped if template did not change and --force is applied')
  #
  # The origin's harness leaves the deployed template different, so its
  # assertion holds either way; the name pins the intent, and the port deploys
  # an unchanged stack with --force.
  def test_deploy_not_skipped_if_template_did_not_change_and_force_is_applied
    given_no_updates_are_to_be_performed(client)

    result = deploy(client, body: target_template, options: unattended(force: true))

    assert_equal :deployed, result.outcome
    assert_equal 1, client.calls_to(:execute_change_set).length
  end

  # test('deploy is skipped if template and tags did not change')
  def test_deploy_is_skipped_if_template_and_tags_did_not_change
    given_no_updates_are_to_be_performed(client)
    client.stack(STACK_NAME, template: target_template,
      tags: [ { key: "Key1", value: "Value1" }, { key: "Key2", value: "Value2" } ])

    result = deploy(client, body: target_template,
      options: unattended(tags: { "Key1" => "Value1", "Key2" => "Value2" }))

    assert_equal :no_changes, result.outcome
    assert_empty client.calls_to(:create_change_set)
    assert_empty client.calls_to(:execute_change_set)
    refute_empty client.calls_to(:get_template), "the deployed template is read to decide"
  end

  # test('deploy not skipped if template did not change but tags changed')
  def test_deploy_not_skipped_if_template_did_not_change_but_tags_changed
    client.stack(STACK_NAME, template: target_template, tags: [ { key: "Key", value: "Value" } ])

    result = deploy(client, body: target_template, options: unattended(tags: { "Key" => "NewValue" }))

    assert_equal :deployed, result.outcome
    assert_equal [ { key: "Key", value: "NewValue" } ], client.kwargs_of(:create_change_set).first[:tags]
    assert_equal 1, client.calls_to(:describe_change_set).length
    assert_equal 1, client.calls_to(:execute_change_set).length
  end

  # test('deployStack reports no change if describeChangeSet returns an error that indicates no change')
  def test_deploy_stack_reports_no_change_if_describe_change_set_returns_an_error_that_indicates_no_change
    given_stack_exists(client)
    client.on(:describe_change_set, described(status: "FAILED", status_reason: "The submitted information didn't contain changes."))

    result = deploy(client, body: target_template, options: unattended)

    assert_equal :no_changes, result.outcome
    assert_equal 0, result.exit_code
  end

  # test('deployStack throws error in case of early validation failures')
  #
  # The origin throws 'Early validation failed for change set cdk-deploy-change-set';
  # the engine's rejection names the reason and prints the events with it, exit 3.
  def test_deploy_stack_throws_error_in_case_of_early_validation_failures
    client.on(:describe_change_set, described(status: "FAILED", status_reason: "(AWS::EarlyValidation::SomeError). Blah blah blah."))
    client.on(:operation_events, [ event("VALIDATION_ERROR", logical_id: "MyResource",
      resource_type: "Test::Resource::Type", status_reason: "Resource already exists") ])
    out = D::Fakes::Output.new

    error = assert_raises(D::ChangeSetFailed) do
      deploy(client, out, body: target_template, options: unattended)
    end

    assert_equal 3, D.exit_code_for(error)
    assert_match(/\(AWS::EarlyValidation::SomeError\)/, error.message)
    assert_match(/Resource already exists/, out.failures.first, "the validation events are printed with the reason")
  end

  # test('deployStack warns when it cannot get the events in case of early validation errors')
  #
  # The events are optional here as there: the reason is still reported, and
  # the deploy still fails.
  def test_deploy_stack_warns_when_it_cannot_get_the_events_in_case_of_early_validation_errors
    client.on(:describe_change_set, described(status: "FAILED", status_reason: "(AWS::EarlyValidation::SomeError). Blah blah blah."))
    client.on(:operation_events, RuntimeError.new("AccessDenied"))

    error = assert_raises(D::ChangeSetFailed) do
      deploy(client, body: target_template, options: unattended)
    end

    assert_match(/\(AWS::EarlyValidation::SomeError\)/, error.message, "the reason is reported without the events")
  end

  # test('even if ChangeSet error does not match pattern, DescribeEvents is called')
  def test_even_if_change_set_error_does_not_match_pattern_describe_events_is_called
    client.on(:describe_change_set, described(status: "FAILED",
      status_reason: "Something somewhere went wrong, cannot be more specific than that."))

    assert_raises(D::ChangeSetFailed) { deploy(client, body: target_template, options: unattended) }

    assert_equal 1, client.calls_to(:operation_events).length, "the events of the operation are fetched anyway"
  end

  # test('deploy not skipped if template did not change but one tag removed')
  def test_deploy_not_skipped_if_template_did_not_change_but_one_tag_removed
    client.stack(STACK_NAME, template: target_template,
      tags: [ { key: "Key1", value: "Value1" }, { key: "Key2", value: "Value2" } ])

    result = deploy(client, body: target_template, options: unattended(tags: { "Key1" => "Value1" }))

    assert_equal :deployed, result.outcome
    assert_equal 1, client.calls_to(:execute_change_set).length
  end

  # test('deploy is not skipped if stack is in a _FAILED state')
  #
  # Changed expectation, architecture section 9: the CDK deploys onto
  # DELETE_FAILED and expects CreateChangeSet and ExecuteChangeSet; the
  # six-state table here refuses every status that maps to :rollback_failed,
  # with the way to repair it, before anything is created.
  def test_deploy_is_not_skipped_if_stack_is_in_a_failed_state
    given_stack_exists(client, status: "DELETE_FAILED")

    error = assert_raises(D::StackNeedsRepair) do
      deploy(client, body: target_template, options: unattended)
    end

    assert_equal 1, D.exit_code_for(error)
    assert_empty client.calls_to(:create_change_set)
    assert_empty client.calls_to(:execute_change_set)
  end

  # test('existing stack in UPDATE_ROLLBACK_COMPLETE state can be updated')
  def test_existing_stack_in_update_rollback_complete_state_can_be_updated
    given_stack_exists(client, status: "UPDATE_ROLLBACK_COMPLETE", template: "{ \"changed\": 123 }")

    deploy(client, body: target_template, options: unattended)

    assert_empty client.calls_to(:delete_stack), "a stable stack is not deleted"
    assert_equal :update, client.kwargs_of(:create_change_set).first[:change_set_type]
  end

  # test('deploy not skipped if template changed')
  def test_deploy_not_skipped_if_template_changed
    given_stack_exists(client)

    result = deploy(client, body: target_template, options: unattended)

    assert_equal :deployed, result.outcome
    assert_equal 1, client.calls_to(:create_change_set).length
    assert_equal 1, client.calls_to(:execute_change_set).length
  end

  # test('not executed and no error if --no-execute is given')
  def test_not_executed_and_no_error_if_no_execute_is_given
    result = deploy(client, body: target_template, options: unattended(no_execute: true))

    assert_equal :not_executed, result.outcome
    assert_equal 0, result.exit_code
    assert_empty client.calls_to(:execute_change_set)
  end

  # test('announces the change set as awaiting manual execution if --no-execute is given')
  #
  # The origin's message is 'waiting in review for manual execution
  # (--no-execute)'; the engine announces that the change set was left
  # unexecuted and how to go on.
  def test_announces_the_change_set_as_awaiting_manual_execution_if_no_execute_is_given
    out = D::Fakes::Output.new

    deploy(client, out, body: target_template, options: unattended(no_execute: true))

    announcement = out.announcements.find { |text| text.include?("--no-execute") }
    refute_nil announcement, "the change set is announced as left unexecuted"
    assert_match(/unexecuted/, announcement)
  end

  # test('empty change set is deleted if --execute is given')
  #
  # The first deletion removes the change set a previous run of the same name
  # left, the second the empty one, as in the origin.
  def test_empty_change_set_is_deleted_if_execute_is_given
    given_no_updates_are_to_be_performed(client)
    client.on(:describe_change_set, described(status: "FAILED", status_reason: "The submitted information didn't contain changes."))

    deploy(client, body: target_template, options: unattended(force: true))

    assert_equal 1, client.calls_to(:create_change_set).length
    assert_empty client.calls_to(:execute_change_set)
    deleted = client.calls_to(:delete_change_set).map { |call| call.args[1] }
    assert_equal 2, deleted.length
    assert_equal D::Deployer::CHANGE_SET_NAME, deleted.first
  end

  # test('empty change set is not deleted if --no-execute is given')
  def test_empty_change_set_is_not_deleted_if_no_execute_is_given
    given_stack_exists(client)

    deploy(client, body: target_template, options: unattended(no_execute: true))

    assert_equal 1, client.calls_to(:create_change_set).length
    assert_empty client.calls_to(:execute_change_set)
    deleted = client.calls_to(:delete_change_set).map { |call| call.args[1] }
    assert_equal [ D::Deployer::CHANGE_SET_NAME ], deleted, "only the change set of an earlier run goes"
  end

  # test('changeset is created when stack exists in REVIEW_IN_PROGRESS status')
  def test_changeset_is_created_when_stack_exists_in_review_in_progress_status
    given_stack_exists(client, status: "REVIEW_IN_PROGRESS",
      tags: [ { key: "Key1", value: "Value1" }, { key: "Key2", value: "Value2" } ])

    deploy(client, body: target_template, options: unattended(no_execute: true))

    assert_equal :create, client.kwargs_of(:create_change_set).first[:change_set_type]
    assert_empty client.calls_to(:execute_change_set)
  end

  # test('changeset is updated when stack exists in CREATE_COMPLETE status')
  def test_changeset_is_updated_when_stack_exists_in_create_complete_status
    given_stack_exists(client, tags: [ { key: "Key1", value: "Value1" }, { key: "Key2", value: "Value2" } ])

    deploy(client, body: target_template, options: unattended(no_execute: true))

    assert_equal :update, client.kwargs_of(:create_change_set).first[:change_set_type]
    assert_empty client.calls_to(:execute_change_set)
  end

  # test('deploy with termination protection enabled')
  def test_deploy_with_termination_protection_enabled
    result = deploy(client, stack: cdk_stack(termination_protection: true), body: target_template, options: unattended)

    assert_equal :deployed, result.outcome
    assert_equal [ { enabled: true } ], client.calls_to(:update_termination_protection).map(&:kwargs)
  end

  # test('updateTerminationProtection not called when termination protection is undefined')
  #
  # The engine cannot tell undefined from false; a stack that does not ask for
  # protection leaves a stack without protection alone, which is the case
  # pinned here.
  def test_update_termination_protection_not_called_when_termination_protection_is_undefined
    deploy(client, body: target_template, options: unattended)

    assert_empty client.calls_to(:update_termination_protection)
  end

  # test('updateTerminationProtection called when termination protection is undefined and stack has termination protection')
  def test_update_termination_protection_called_when_termination_protection_is_undefined_and_stack_has_termination_protection
    given_stack_exists(client, termination_protection: true)

    deploy(client, body: target_template, options: unattended)

    assert_equal [ { enabled: false } ], client.calls_to(:update_termination_protection).map(&:kwargs)
  end

  # describe('disable rollback')

  # test('by default, we do not disable rollback (and also do not pass the flag)')
  #
  # The origin checks the flag is not on the command; the engine's kwarg says
  # false, which is the same answer.
  def test_by_default_we_do_not_disable_rollback
    deploy(client, body: target_template, options: unattended)

    assert_equal 1, client.calls_to(:execute_change_set).length
    assert_equal false, client.kwargs_of(:execute_change_set).first[:disable_rollback]
  end

  # test('rollback can be disabled by setting rollback: false')
  #
  # The origin gives no existing stack, and passes DisableRollback on the
  # execution of a creation too; this engine pairs OnStackFailure with a
  # creation and --no-rollback with an update (architecture section 9), so the
  # scenario is run against a stack that exists, where the flag is carried.
  def test_rollback_can_be_disabled_by_setting_rollback_false
    given_stack_exists(client)

    deploy(client, body: target_template, options: unattended(no_rollback: true))

    assert_equal :update, client.kwargs_of(:create_change_set).first[:change_set_type]
    assert_equal true, client.kwargs_of(:execute_change_set).first[:disable_rollback]
  end

  # test.each('no-rollback and replacement is disadvised: %s %s %s -> %s')
  #
  # Changed expectation, first row (UPDATE_FAILED, no rollback, no
  # replacement): the CDK fix-forwards onto the failed stack and answers
  # 'did-deploy-stack'; the six-state table of architecture section 9 refuses
  # every status that maps to :rollback_failed, so the port expects the
  # refusal the engine gives, with nothing executed.
  #
  # FINDING, last row (UPDATE_COMPLETE, no rollback, replacement): the CDK
  # refuses to execute a change set that replaces a resource when rollback is
  # disabled, and answers 'replacement-requires-rollback' without executing
  # anything (lib/api/deployments/deploy-stack.ts, checkAndExecuteChangeSet:
  # `if (!rollbackEnabled && replacement) return { type:
  # 'replacement-requires-rollback' }`). This engine has no replacement check:
  # it executes the change set with disable_rollback and answers :deployed, so
  # the row fails here. The engine is wrong or the contract is; nothing in
  # section 21 records the difference.
  #
  # The rows refused by both expect StackNeedsRepair (exit 1) here where the
  # origin answers 'failpaused-need-rollback-first': the refusal itself is
  # what the port holds to.
  NO_ROLLBACK_AND_REPLACEMENT = [
    # [ stack status, rollback?, replacement?, what the CDK answers ]
    [ "UPDATE_FAILED", false, false, :deploys ],
    [ "UPDATE_FAILED", false, true, :refused ],
    [ "UPDATE_FAILED", true, true, :refused ],
    [ "UPDATE_FAILED", true, false, :refused ],
    [ "UPDATE_COMPLETE", false, true, :refused ]
  ].freeze

  def test_no_rollback_and_replacement_is_disadvised
    NO_ROLLBACK_AND_REPLACEMENT.each do |status, rollback, replacement, cdk_answer|
      client = D::Fakes::CfnClient.new
      client.stack(STACK_NAME, status: status, template: start_template)
      client.on(:describe_change_set, described(changes: [
        change(action: "Modify", logical_id: "MyResource", replacement: replacement ? "True" : "False")
      ]))
      # forceDeployment bypasses the origin's skip rule; the port does the same.
      options = unattended(force: true, no_rollback: !rollback)

      error = assert_raises(D::StackNeedsRepair,
        "#{status} rollback=#{rollback} replacement=#{replacement} (the CDK answers #{cdk_answer})") do
        deploy(client, body: target_template, options: options)
      end

      assert_equal 1, D.exit_code_for(error)
      assert_empty client.calls_to(:execute_change_set), "nothing is executed"
    end
  end

  # describe('change set returned with execute:false')

  # test('returns changeSet description when execute is false')
  #
  # The origin returns the change set description for the approval diff; the
  # engine's result carries the changes, and they are shown.
  def test_returns_change_set_description_when_execute_is_false
    given_stack_exists(client)

    result = deploy(client, body: target_template, options: unattended(no_execute: true))

    assert_equal :not_executed, result.outcome
    refute_empty result.changes
    assert_equal "Modify", result.changes.first.action
  end

  # test('does not return changeSet when change set is empty')
  def test_does_not_return_change_set_when_change_set_is_empty
    given_no_updates_are_to_be_performed(client)
    client.on(:describe_change_set, described(status: "FAILED", status_reason: "The submitted information didn't contain changes."))

    result = deploy(client, body: target_template, options: unattended(no_execute: true))

    assert_equal :no_changes, result.outcome
    assert_empty result.changes
    assert_empty client.calls_to(:execute_change_set)
  end
end
