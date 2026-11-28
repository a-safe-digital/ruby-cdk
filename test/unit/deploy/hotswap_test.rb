# frozen_string_literal: true

require "test_helper"
require "support/deploy_fixtures"

# The hotswap fast path of the engine (architecture section 9): what
# `deploy --hotswap` and `deploy --hotswap-fallback` apply with update_stack,
# what falls back to the change set, and what is reported and ignored. The
# classification itself is held by the CDK's own cases, ported under
# test/cdk/cli/hotswap_test.rb; these hold the engine around it: the requests
# through the fake, the reporting, the facts a result carries, and the ways a
# deploy ends when the fast path is not taken.
class DeployHotswapTest < Minitest::Test
  include DeployFixtures
  D = RubyCdk::Deploy

  FUNCTION = "AWS::Lambda::Function"

  def lambda_template(code_key:, **properties)
    template(resources: { "Func" => { "Type" => FUNCTION, "Properties" => {
      "Code" => { "S3Bucket" => "assets", "S3Key" => code_key }, "FunctionName" => "my-function", **properties
    } } })
  end

  def given_deployed_function(client, code_key: "old-key", **properties)
    client.stack("blog", status: "UPDATE_COMPLETE", template: lambda_template(code_key: code_key, **properties))
  end

  def hotswap_options(**options)
    unattended(hotswap: true, **options)
  end

  def fallback_options(**options)
    unattended(hotswap_fallback: true, **options)
  end

  def deploy_hotswap(client, body, output = D::Fakes::Output.new, options: hotswap_options)
    deploy(client, output, body: body, options: options)
  end

  # --- the fast path: update_stack, not a change set

  def test_a_code_change_is_applied_with_update_stack_and_no_change_set
    client = D::Fakes::CfnClient.new
    given_deployed_function(client)
    output = D::Fakes::Output.new

    result = deploy_hotswap(client, lambda_template(code_key: "new-key"), output)

    assert_equal :deployed, result.outcome
    assert_equal 0, result.exit_code
    assert_empty client.calls_to(:create_change_set), "no change set: the fast path skips it"
    assert_empty client.calls_to(:execute_change_set)
    assert_equal 1, client.calls_to(:update_stack).size
    assert_equal "blog", client.calls_to(:update_stack).first.args.first
    request = client.kwargs_of(:update_stack).first
    assert_includes request[:template], "new-key", "the whole new template goes in the request"
    assert_equal [], request[:parameters]
    assert_equal [], request[:tags]
    assert_equal [], request[:capabilities]
    assert_equal "UPDATE_COMPLETE", client.stack_record("blog").status
  end

  def test_the_result_carries_the_hotswap_facts_of_what_was_applied
    client = D::Fakes::CfnClient.new
    given_deployed_function(client)

    result = deploy_hotswap(client, lambda_template(code_key: "new-key"))

    facts = result.hotswap
    assert_equal "hotswap-only", facts.mode
    refute facts.fell_back
    assert_equal [ { logical_id: "Func", resource_type: FUNCTION, name: "my-function" } ],
      facts.swapped.map(&:to_h)
    assert_empty facts.non_hotswappable
  end

  def test_a_configuration_change_is_applied_the_same_way
    client = D::Fakes::CfnClient.new
    given_deployed_function(client, "MemorySize" => 128)

    result = deploy_hotswap(client, lambda_template(code_key: "old-key", "MemorySize" => 512, "Timeout" => 30))

    assert_equal :deployed, result.outcome
    assert_equal 1, client.calls_to(:update_stack).size
    assert_equal [ { logical_id: "Func", resource_type: FUNCTION, name: "my-function" } ],
      result.hotswap.swapped.map(&:to_h)
  end

  def test_capabilities_of_the_whole_template_accompany_the_update
    client = D::Fakes::CfnClient.new
    function = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "b", "S3Key" => "old" }, "FunctionName" => "f" } }
    role = { "Type" => "AWS::IAM::Role", "Properties" => { "AssumeRolePolicyDocument" => { "Statement" => [] } } }
    client.stack("blog", status: "UPDATE_COMPLETE", template: template(resources: { "Func" => function, "Role" => role }))
    body = template(resources: {
      "Func" => { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "b", "S3Key" => "new" }, "FunctionName" => "f" } },
      "Role" => role
    })

    result = deploy_hotswap(client, body)

    assert_equal :deployed, result.outcome
    assert_equal [ "CAPABILITY_IAM" ], client.kwargs_of(:update_stack).first[:capabilities],
      "the capabilities of the whole template, as the change set would carry"
  end

  def test_the_events_of_the_update_are_followed_and_the_failure_is_exit_5
    client = D::Fakes::CfnClient.new
    given_deployed_function(client)
    client.on(:update_stack, lambda do |call|
      record = client.stack_record(call.args.first)
      record.status = "UPDATE_ROLLBACK_COMPLETE"
      client.emit(call.args.first, "UPDATE_COMPLETE", logical_id: "Func", resource_type: FUNCTION, at: Time.utc(2026, 1, 1))
      client.emit(call.args.first, "UPDATE_FAILED", logical_id: "Func", resource_type: FUNCTION, status_reason: "broken",
        at: Time.utc(2026, 1, 2))
      nil
    end)
    output = D::Fakes::Output.new

    result = deploy_hotswap(client, lambda_template(code_key: "new-key"), output)

    assert_equal :failed, result.outcome
    assert_equal 5, result.exit_code
    refute_empty output.failures, "the resources that failed are printed, as after a change set"
  end

  # --- what the CDK prints, ported

  def test_the_lines_of_a_hotswap_are_the_cdk_s
    client = D::Fakes::CfnClient.new
    given_deployed_function(client)
    output = D::Fakes::Output.new

    deploy_hotswap(client, lambda_template(code_key: "new-key"), output)

    lines = output.announcements
    assert_includes lines, "\n✨ hotswapping resources:"
    assert_includes lines, "   ✨ AWS::Lambda::Function 'my-function'"
    assert_includes lines, "   ✨ AWS::Lambda::Function 'my-function' hotswapped!"
  end

  def test_a_function_without_a_literal_name_is_reported_by_its_logical_id
    client = D::Fakes::CfnClient.new
    named = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "b", "S3Key" => "old" }, "FunctionName" => { "Ref" => "Param" } } }
    client.stack("blog", status: "UPDATE_COMPLETE", template: template(resources: { "Func" => named }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "b", "S3Key" => "new" }, "FunctionName" => { "Ref" => "Param" } } }
    output = D::Fakes::Output.new

    deploy_hotswap(client, template(resources: { "Func" => renamed }), output)

    assert_equal 1, client.calls_to(:update_stack).size
    assert_includes output.announcements, "   ✨ AWS::Lambda::Function 'Func' hotswapped!"
  end

  # --- --hotswap: what cannot be applied is reported and ignored

  def test_a_change_the_fast_path_cannot_carry_is_reported_and_ignored_under_hotswap
    client = D::Fakes::CfnClient.new
    client.stack("blog", status: "UPDATE_COMPLETE", template: template(resources: { "Bucket" => { "Type" => "AWS::S3::Bucket" } }))
    output = D::Fakes::Output.new

    result = deploy_hotswap(client, template(resources: { "Bucket" => { "Type" => "AWS::S3::Bucket",
      "Properties" => { "BucketName" => "renamed" } } }), output)

    assert_equal :no_changes, result.outcome, "nothing was applied, and the deploy is not a failure"
    assert_equal 0, result.exit_code
    assert_empty client.calls_to(:update_stack)
    assert_empty client.calls_to(:create_change_set), "--hotswap does not fall back on its own"
    assert_includes output.announcements,
      "⚠️ The following non-hotswappable changes were found. To reconcile these using CloudFormation, specify --hotswap-fallback"
    assert_includes output.announcements,
      "    resource: Bucket, type: AWS::S3::Bucket, reason: This resource type is not supported for hotswap deployments"
    assert_empty result.hotswap.swapped
    assert_equal 1, result.hotswap.non_hotswappable.length
  end

  def test_a_mixed_change_is_not_applied_in_part_under_hotswap
    client = D::Fakes::CfnClient.new
    client.stack("blog", status: "UPDATE_COMPLETE", template: template(resources: {
      "Func" => { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "b", "S3Key" => "old" }, "FunctionName" => "f" } },
      "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "kept" } }
    }))
    output = D::Fakes::Output.new
    body = template(resources: {
      "Func" => { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "b", "S3Key" => "new" }, "FunctionName" => "f" } },
      "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "renamed" } }
    })

    result = deploy_hotswap(client, body, output)

    assert_equal :no_changes, result.outcome
    assert_empty client.calls_to(:update_stack), "one update_stack carries the whole template: a mixed diff is applied whole or not at all"
    assert_empty client.calls_to(:create_change_set)
    assert_empty result.hotswap.swapped, "the hotswappable half is not applied either"
    assert_equal [ "Bucket" ], result.hotswap.non_hotswappable.map(&:logical_id)
  end

  def test_a_new_resource_is_a_creation_the_fast_path_does_not_carry
    client = D::Fakes::CfnClient.new
    given_deployed_function(client)
    output = D::Fakes::Output.new
    body = template(resources: {
      "Func" => { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "b", "S3Key" => "new" }, "FunctionName" => "my-function" } },
      "Queue" => { "Type" => "AWS::SQS::Queue" }
    })

    result = deploy_hotswap(client, body, output, options: fallback_options)

    assert_equal :deployed, result.outcome
    assert_includes output.announcements,
      "    resource: Queue, type: AWS::SQS::Queue, reason: resource 'Queue' was created by this deployment"
    assert_equal [ "Queue" ], result.hotswap.non_hotswappable.map(&:logical_id)
  end

  def test_an_absent_stack_is_all_creations_and_hotswap_deploys_nothing
    client = D::Fakes::CfnClient.new
    output = D::Fakes::Output.new

    result = deploy_hotswap(client, lambda_template(code_key: "new-key"), output)

    assert_equal :no_changes, result.outcome, "the CDK's hotswap-only ignores what it cannot apply, creations included"
    assert_empty client.calls_to(:create_change_set)
    assert_empty client.calls_to(:update_stack)
  end

  # --- --hotswap-fallback: the change set takes the deploy

  def test_a_change_the_fast_path_cannot_carry_falls_back_to_the_change_set
    client = D::Fakes::CfnClient.new
    client.stack("blog", status: "UPDATE_COMPLETE", template: template(resources: { "Bucket" => { "Type" => "AWS::S3::Bucket" } }))
    output = D::Fakes::Output.new

    result = deploy_hotswap(client, template(resources: { "Bucket" => { "Type" => "AWS::S3::Bucket",
      "Properties" => { "BucketName" => "renamed" } } }), output, options: fallback_options)

    assert_equal :deployed, result.outcome
    assert_equal 1, client.calls_to(:create_change_set).size
    assert_equal 1, client.calls_to(:execute_change_set).size
    assert_includes output.announcements, "Could not perform a hotswap deployment, as the stack blog contains non-Asset changes"
    assert_includes output.announcements, "Falling back to doing a full deployment"
    facts = result.hotswap
    assert_equal "fall-back", facts.mode
    assert facts.fell_back
    assert_empty facts.swapped
    assert_equal [ "Bucket" ], facts.non_hotswappable.map(&:logical_id)
  end

  def test_a_fallen_back_deploy_still_carries_the_whole_change_set_result
    client = D::Fakes::CfnClient.new
    client.stack("blog", status: "UPDATE_COMPLETE", template: template(resources: { "Bucket" => { "Type" => "AWS::S3::Bucket" } }))

    result = deploy_hotswap(client, template(resources: { "Bucket" => { "Type" => "AWS::S3::Bucket",
      "Properties" => { "BucketName" => "renamed" } } }), D::Fakes::Output.new, options: fallback_options)

    assert_equal 1, result.changes.length, "the change view of the change set comes with the result"
    assert_equal "Modify", result.changes.first.action
  end

  def test_an_evaluation_that_cannot_read_the_deployed_template_falls_back
    client = D::Fakes::CfnClient.new
    client.stack("blog", status: "UPDATE_COMPLETE", template: lambda_template(code_key: "old-key"))
    # The first read is the skip rule's, and answers; the evaluation's read is refused.
    client.on(:get_template, lambda_template(code_key: "old-key"), RubyCdk::PreconditionError.new("ThrottlingException: slow down"))
    output = D::Fakes::Output.new

    result = deploy_hotswap(client, lambda_template(code_key: "new-key"), output, options: fallback_options)

    assert_equal :deployed, result.outcome, "the template could not be read, so the change set decides"
    assert_equal 1, client.calls_to(:create_change_set).size
    assert_includes output.announcements,
      "Could not perform a hotswap deployment, because the CloudFormation template could not be resolved."
    assert result.hotswap.fell_back
  end

  def test_an_evaluation_that_cannot_read_the_deployed_template_deploys_nothing_under_hotswap
    client = D::Fakes::CfnClient.new
    client.stack("blog", status: "UPDATE_COMPLETE", template: lambda_template(code_key: "old-key"))
    client.on(:get_template, lambda_template(code_key: "old-key"), RubyCdk::PreconditionError.new("ThrottlingException: slow down"))

    result = deploy_hotswap(client, lambda_template(code_key: "new-key"), D::Fakes::Output.new)

    assert_equal :no_changes, result.outcome
    assert_empty client.calls_to(:create_change_set)
  end

  # --- the skip rule, the approval, and the race

  def test_an_unchanged_deploy_under_hotswap_is_skipped_with_the_cdk_s_line
    client = D::Fakes::CfnClient.new
    body = lambda_template(code_key: "old-key")
    client.stack("blog", status: "UPDATE_COMPLETE", template: body)
    output = D::Fakes::Output.new

    result = deploy_hotswap(client, body, output)

    assert_equal :no_changes, result.outcome
    assert_empty client.calls_to(:update_stack)
    assert_empty client.calls_to(:create_change_set)
    assert_includes output.announcements, "✨ hotswap deployment skipped - no changes were detected (use --force to override)"
    assert_equal "hotswap-only", result.hotswap.mode
    refute result.hotswap.fell_back
  end

  def test_the_hotswap_asks_before_it_applies_and_nothing_is_applied_without_approval
    client = D::Fakes::CfnClient.new
    given_deployed_function(client)
    output = D::Fakes::Output.new(approvals: false)

    error = assert_raises(D::ApprovalRequired) do
      deploy_hotswap(client, lambda_template(code_key: "new-key"), output, options: hotswap_options(yes: false))
    end

    assert_includes error.message, "Approval for the hotswap of stack blog was not given, so nothing was applied."
    assert_empty client.calls_to(:update_stack)
  end

  def test_the_approval_is_asked_with_the_target_in_the_question
    client = D::Fakes::CfnClient.new
    given_deployed_function(client)
    output = D::Fakes::Output.new(approvals: true)

    deploy_hotswap(client, lambda_template(code_key: "new-key"), output, options: hotswap_options(yes: false))

    assert_equal [ "Hotswap these changes to stack blog in account #{D::Fakes::CfnClient::ACCOUNT} (#{D::Fakes::CfnClient::REGION})?" ],
      output.questions
  end

  def test_an_update_cloudformation_refuses_as_a_no_op_ends_without_a_failure
    client = D::Fakes::CfnClient.new
    given_deployed_function(client)
    client.on(:update_stack, RubyCdk::PreconditionError.new("ValidationError: No updates are to be performed."))
    output = D::Fakes::Output.new

    result = deploy_hotswap(client, lambda_template(code_key: "new-key"), output)

    assert_equal :no_changes, result.outcome
    assert_equal 0, result.exit_code
    assert_includes output.announcements, "blog: CloudFormation reports that the update would change nothing. Nothing was applied."
  end

  def test_any_other_refusal_of_the_update_is_an_error
    client = D::Fakes::CfnClient.new
    given_deployed_function(client)
    client.on(:update_stack, RubyCdk::PreconditionError.new("ValidationError: Template format error"))

    error = assert_raises(RubyCdk::PreconditionError) do
      deploy_hotswap(client, lambda_template(code_key: "new-key"), D::Fakes::Output.new)
    end

    assert_includes error.message, "Template format error"
  end

  # --- deploy without the flags: nothing changes

  def test_without_the_flags_there_is_no_update_stack_and_no_facts
    client = D::Fakes::CfnClient.new
    given_deployed_function(client)

    result = deploy(client, D::Fakes::Output.new, body: lambda_template(code_key: "new-key"), options: unattended)

    assert_equal :deployed, result.outcome
    assert_nil result.hotswap, "the facts are a --hotswap contract; a change-set deploy carries none"
    assert_equal 1, client.calls_to(:create_change_set).size
    assert_empty client.calls_to(:update_stack)
  end
end
