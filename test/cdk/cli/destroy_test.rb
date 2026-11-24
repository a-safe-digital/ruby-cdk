# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/@aws-cdk/toolkit-lib/test/actions/destroy.test.ts,
#            in aws/aws-cdk-cli
#   Commit:  eca1b73d682d7763955bec30ab5dd52bbc4327b6 (main, read on 2026-11-24)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin holds 25 cases, in describe('destroy') (18) and describe('stacks
# nested in a stage') (7). Each ported one keeps its name, as a comment above
# the test. The scenarios there run Toolkit#destroy against a mocked
# Deployments; here they run Deployer#destroy against the scripted fake of
# lib/ruby_cdk/deploy/fakes.rb, through the harness of support/cdk_deploy.rb.
#
# Ported with an expectation changed, where this tool differs by design, said
# next to the expectation:
#   - request response before destroying: the CDK asks a yes/no question
#     ("Are you sure you want to delete: Stack1", lib/toolkit/toolkit.ts,
#     _destroy, CDK_TOOLKIT_I7010); this engine prints what the stack keeps and
#     asks the person to type the stack name (architecture section 9), which
#     is stricter than a yes/no. The port holds to what the two share: a
#     confirmation is requested, and nothing is deleted without it.
#   - destroy deployment fails: a stack operation that failed is raised by the
#     CDK's toolkit; this engine returns it, as a DeployResult with outcome
#     :failed and exit code 5, after printing the resources that failed
#     (architecture section 21, "a stack operation that failed").
#   - warns when no stacks match the given name(s): the CDK's warning comes
#     from its pattern matching ("No stacks match the name(s)"); this command
#     takes exact names (architecture section 11), so at the engine's seam the
#     name that matches nothing is the absent stack, and the engine announces
#     that there is nothing to destroy. The content the two share: the name is
#     reported, nothing is deleted, and the command does not fail.
#
# Not ported, with the reason:
#
#   The command line owns stack selection (architecture section 9: no
#   argument takes the app's single stack, --all takes every stack; the
#   engine's API is one stack per call), so these have no engine scenario:
#   - multiple stacks;
#   - destroy with concurrency;
#   - warns about a missing name but still destroys the matching stacks;
#   - destroys all top-level stacks with the MAIN_ASSEMBLY strategy
#     (cdk destroy --all);
#   - destroys the single stack with the ONLY_SINGLE strategy (cdk destroy
#     with no patterns).
#
#   Express mode, which this tool does not have:
#   - warns about resources still tearing down in Express Mode;
#   - does not warn about tearing down resources when not in Express Mode;
#   - express option is passed in.
#
#   Options and lifecycle of the CDK's toolkit that the engine does not have:
#   - stackEventPollingInterval option is passed in (the engine takes its
#     pollers as arguments);
#   - action disposes of assembly produced by source (there is no cloud
#     assembly; the app is Ruby objects in one process).
#
#   Stack selection this version does not have (architecture section 11:
#   names are exact; wildcards, exclusions and suggestions are backlog):
#   - suggests a closely matching stack when the name does not exist;
#   - suggests a closely matching stack when an exclusion does not exist;
#   - a stack cancelled out by an exclusion is not reported as missing;
#   - warns about every non-existent name when none of them match.
#
#   Stages and nested apps, which this tool does not have (docs/07-testing.md
#   section 12), describe('stacks nested in a stage') whole:
#   - destroys a stack inside a stage by its hierarchical id;
#   - destroys a staged stack via a wildcard pattern;
#   - destroys a stack in a stage-only app (no top-level stacks);
#   - destroys a staged stack via wildcard in a stage-only app;
#   - warns without failing for a non-existent name in a stage-only app;
#   - suggests a nested-stage stack when only the casing differs;
#   - suggests a nested-stage stack for a wildcard pattern that differs only
#     in case.
#
# Parity: 25 cases in the origin; 4 ported; 21 not ported.

require "test_helper"
require "support/deploy_fixtures"
require "support/cdk_deploy"

class CdkCliDestroyTest < Minitest::Test
  include CdkDeploy
  D = RubyCdk::Deploy

  def client
    @client ||= D::Fakes::CfnClient.new
  end

  # describe('destroy')

  # test('destroy from builder')
  #
  # The selection of the app's stacks is the command line's (architecture
  # section 9); at the engine's seam the scenario is the destroy itself: the
  # stack is destroyed and the result says so.
  def test_destroy_from_builder
    given_stack_exists(client, name: "Stack1")

    result = destroy(client, stack: cdk_stack(name: "Stack1"), options: unattended)

    assert_equal :destroyed, result.outcome
    assert_equal 0, result.exit_code
    assert_equal "DELETE_COMPLETE", client.stack_record("Stack1").status
  end

  # test('request response before destroying')
  #
  # Changed expectation: the CDK asks yes/no ("Are you sure you want to
  # delete: Stack1"); this engine prints what the stack keeps and asks the
  # person to type the stack name (architecture section 9). What the two share
  # holds here: the question comes before any deletion, and only the right
  # answer lets it through.
  def test_request_response_before_destroying
    given_stack_exists(client, name: "Stack1")
    out = D::Fakes::Output.new(confirmations: "Stack1")

    result = destroy(client, out, stack: cdk_stack(name: "Stack1"), options: D::DeployOptions.new)

    assert_equal %i[target retained confirm], out.calls.map(&:operation),
      "what is kept is said, then the person is asked, before anything happens"
    assert_equal [ "Stack1" ], out.confirmations, "the answer is the stack name itself"
    assert_equal :destroyed, result.outcome
    assert_equal 1, client.calls_to(:delete_stack).length
  end

  # test('destroy deployment fails')
  #
  # Changed expectation, architecture section 21: a stack operation that
  # failed is raised by the CDK's toolkit; this engine returns it, as a
  # DeployResult with outcome :failed and exit code 5, after printing the
  # resources that failed.
  def test_destroy_deployment_fails
    given_stack_exists(client, name: "Stack1")
    client.on(:delete_stack, lambda { |_call|
      client.stack_record("Stack1").status = "DELETE_FAILED"
      client.emit("Stack1", "DELETE_FAILED", logical_id: "Bucket", resource_type: "AWS::S3::Bucket",
        status_reason: "The bucket is not empty")
    })
    out = D::Fakes::Output.new

    result = destroy(client, out, stack: cdk_stack(name: "Stack1"), options: unattended)

    assert_equal :failed, result.outcome
    assert_equal 5, result.exit_code
    assert_match(/could not be deleted/, out.failures.first)
    assert_match(/Bucket \(AWS::S3::Bucket\) DELETE_FAILED: The bucket is not empty/, out.failures.first)
  end

  # test('warns when no stacks match the given name(s)')
  #
  # Changed expectation: the CDK warns through its pattern matching ("No
  # stacks match the name(s)"); this command takes exact names (architecture
  # section 11), so the name that matches nothing is the absent stack, and the
  # engine announces that there is nothing to destroy. What the two share: the
  # name is reported, nothing is deleted, and the command does not fail.
  def test_warns_when_no_stacks_match_the_given_names
    out = D::Fakes::Output.new

    result = destroy(client, out, stack: cdk_stack(name: "DoesNotExist"), options: unattended)

    assert_equal :no_changes, result.outcome
    assert_equal 0, result.exit_code
    assert out.announcements.any? { |text| text.include?("does not exist") }
    assert_empty client.calls_to(:delete_stack)
  end
end
