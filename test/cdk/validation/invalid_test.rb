# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/cloudformation-include/test/invalid-templates.test.ts
#           (the checks it tests: core/lib/helpers-internal/cfn-parse.ts,
#           cloudformation-include/lib/cfn-include.ts, and the feature flag
#           cfnIncludeRejectComplexResourceUpdateCreatePolicyIntrinsics of
#           cx-api/lib/features.ts)
#   Commit: 68b2516c09791d78b199f30e455e4670dc9cde6d (aws/aws-cdk, main)
#   Licence: Apache-2.0
#
#   Cases: 42 in the original. 30 ported, 12 not ported.
#
#   Not ported, with the reason:
#   - "throws an exception when encountering a CFN function it doesn't support"
#     (only-codecommit-repo-using-cfn-functions.json), "throws a validation
#     exception when a Rule references a Parameter that isn't in the template"
#     (rule-referencing-a-non-existent-parameter.json): both are checks of the
#     include's parser, over Fn::ValueOfAll and Fn::ValueOf, intrinsics of the
#     Rules section. This tool has no include; a function it does not know is
#     left to CloudFormation, which knows all of them.
#   - "accepts a cycle between resources in the template if allowed" and the
#     two cases after it: they exercise `allowCyclicalReferences`, an option
#     of the include. This tool always refuses a cycle (rule V14), which the
#     three cases before these pin.
#   - "FF toggles error checking" and "FF disabled with dehydratedResources
#     does not throw": this tool has no feature flag, architecture section 6
#     makes the refusal of policy intrinsics unconditional.
#   - "FF disabled with dehydratedResources does not throw", "dehydrated
#     resources retain attributes with complex Intrinsics", "dehydrated
#     resources retain all attributes", "synth-time validation does not run on
#     dehydrated resources 1 and 2", "throws on dehydrated resources not
#     present in the template": all are about `dehydratedResources`, which
#     this tool has no equivalent of.
#
#   Changed, with nothing else in a scenario, an input or an outcome:
#   - The CDK refuses a template while reading it, with one exception; this
#     tool collects every issue of every rule and reports them together, so a
#     case here asserts the rule and the substance of the CDK's message rather
#     than one thrown sentence.
#   - "throws an exception for a template with a short-form Fn::GetAtt whose
#     string argument does not contain a dot" reads a YAML fixture; this wave
#     reads JSON, so the case carries the same template written as a Hash.
#   - "throws an exception for a template with a non-number string passed to a
#     property with type 'number'" fails at synthesis in the CDK; here it is
#     rule V6, architecture section 6.
#
# Parity: 42 cases in the origin; 30 ported; 12 not ported.

require "json"
require_relative "fixtures"

# The CDK's invalid templates, over this tool's rules.
class CdkValidationInvalidTest < Minitest::Test
  include ValidationFixtures

  # --- what a resource says about its own properties

  def test_a_template_with_a_missing_required_top_level_resource_property
    assert_refused "invalid/bucket-policy-without-bucket", "V5", /Bucket/
  end

  def test_a_resource_property_expecting_an_array_assigned_the_wrong_type
    assert_refused "invalid/bucket-with-cors-rules-not-an-array", "V7", /where a list is expected/
  end

  def test_a_null_array_element_of_a_complex_type_with_required_fields
    assert_refused "invalid/bucket-with-cors-rules-null-element", "V5", /AllowedMethods/
  end

  def test_a_template_with_a_missing_nested_resource_property
    assert_refused "invalid/bucket-with-invalid-cors-rule", "V5", /AllowedOrigins/
  end

  def test_a_non_number_string_passed_to_a_property_with_type_number
    assert_refused "invalid/alphabetical-string-passed-to-number", "V6", /abc/
  end

  # --- what the template refers to

  def test_a_depends_on_that_does_not_exist
    assert_refused "invalid/non-existent-depends-on", "V11", /Bucket1/
  end

  def test_a_condition_in_the_conditions_section_that_does_not_exist
    assert_refused "invalid/non-existent-condition-in-conditions", "V11", /AlwaysFalse/
  end

  def test_a_fn_get_att_in_the_conditions_section
    assert_refused "invalid/getatt-in-conditions", "V22", /Conditions/
  end

  def test_a_condition_resource_attribute_that_does_not_exist
    assert_refused "invalid/non-existent-condition", "V11", /AlwaysFalseCond/
  end

  def test_a_condition_in_an_if_expression_that_does_not_exist
    assert_refused "invalid/non-existent-condition-in-if", "V11", /AlwaysFalse/
  end

  def test_a_ref_to_a_template_element_that_does_not_exist
    assert_refused "invalid/ref-ing-a-non-existent-element", "V8", /DoesNotExist/
  end

  def test_a_get_att_reference_to_a_resource_that_does_not_exist
    assert_refused "invalid/getting-attribute-of-a-non-existent-resource", "V9", /DoesNotExist/
  end

  def test_a_ref_inside_an_unrecognized_resource_attribute_is_refused_as_one_at_a_known_place_is
    assert_refused "invalid/non-existent-resource-attribute", "V8", /NonExistentResource/
  end

  def test_an_output_referencing_a_nonexistent_condition
    assert_refused "invalid/output-referencing-nonexistent-condition", "V11", /NonexistentCondition/
  end

  def test_a_resource_property_referencing_a_mapping_that_does_not_exist
    assert_refused "invalid/non-existent-mapping", "V11", /NonExistentMapping/
  end

  def test_tags_with_invalid_intrinsics
    assert_refused "invalid/tags-with-invalid-intrinsics", "V11", /NonExistentCondition/
  end

  # --- Fn::Sub

  def test_a_fn_sub_in_string_form_uses_a_key_not_in_the_template
    assert_refused "invalid/fn-sub-key-not-in-template-string", "V10", /AFakeResource/
  end

  def test_a_fn_sub_with_an_empty_reference
    assert_refused "invalid/fn-sub-${}-only", "V20", /empty/
  end

  def test_a_short_form_fn_get_att_whose_string_argument_does_not_contain_a_dot
    # The CDK's fixture is short-form-get-att-no-dot.yaml; this wave reads JSON, so the
    # same template stands here as a Hash.
    template = {
      "Resources" => {
        "Bucket1" => { "Type" => "AWS::S3::Bucket" },
        "Bucket2" => {
          "Type" => "AWS::S3::Bucket",
          "Metadata" => { "Bucket1Arn" => { "Fn::GetAtt" => "Bucket1Arn" } }
        }
      }
    }
    report = validate_template(template)

    assert_equal [ "V21" ], report.errors.map(&:rule)
    assert_match(/must contain a "\." in its string argument, got: "Bucket1Arn"/, report.errors.first.message)
  end

  # --- cycles

  def test_a_cycle_between_resources_in_the_template
    report = report_of("invalid/cycle-in-resources")

    assert_equal({ "V14" => 1 }, report.errors.map(&:rule).tally)
    assert_includes report.errors.first.message, "Bucket1 depends on Bucket2 depends on Bucket1"
  end

  def test_multiple_cycles_between_resources_in_the_template
    report = report_of("invalid/multi-cycle-in-resources")

    assert_equal [ "V14" ], report.errors.map(&:rule).uniq
    assert_includes report.errors.map(&:message).join(" "),
      "Bucket1 depends on Bucket2 depends on Bucket3 depends on Bucket4 depends on Bucket2"
  end

  def test_multiple_cycles_with_multiple_destinations_between_resources
    report = report_of("invalid/multi-cycle-multi-dest-in-resources")

    assert_equal [ "V14" ], report.errors.map(&:rule).uniq
    assert_includes report.errors.map(&:message).join(" "), "Bucket1 depends on Bucket2 depends on Bucket3 depends on Bucket1"
  end

  # --- intrinsics inside the creation and update policies

  def test_non_leaf_intrinsics_cannot_be_used_in_the_top_level_creation_policy
    assert_refused "invalid/intrinsics-create-policy", "V23", /CreationPolicy/
  end

  def test_intrinsics_cannot_be_used_in_the_autoscaling_creation_policy
    assert_refused "invalid/intrinsics-create-policy-autoscaling", "V23", /AutoScalingCreationPolicy/
  end

  def test_intrinsics_cannot_be_used_in_the_create_policy_resource_signal
    assert_refused "invalid/intrinsics-create-policy-resource-signal", "V23", /ResourceSignal/
  end

  def test_intrinsics_cannot_be_used_in_the_top_level_update_policy
    assert_refused "invalid/intrinsics-update-policy", "V23", /UpdatePolicy/
  end

  def test_intrinsics_cannot_be_used_in_the_auto_scaling_rolling_update_policy
    assert_refused "invalid/intrinsics-update-policy-autoscaling-rolling-update", "V23", /AutoScalingRollingUpdate/
  end

  def test_intrinsics_cannot_be_used_in_the_auto_scaling_replacing_update_policy
    assert_refused "invalid/intrinsics-update-policy-autoscaling-replacing-update", "V23", /AutoScalingReplacingUpdate/
  end

  def test_intrinsics_cannot_be_used_in_the_auto_scaling_scheduled_action_policy
    assert_refused "invalid/intrinsics-update-policy-autoscaling-scheduled-action", "V23", /AutoScalingScheduledAction/
  end

  def test_intrinsics_cannot_be_used_in_the_code_deploy_lambda_alias_update_policy
    assert_refused "invalid/intrinsics-update-policy-code-deploy-lambda-alias-update", "V23", /CodeDeployLambdaAliasUpdate/
  end

  private

  def assert_refused(fixture, rule, message)
    report = report_of(fixture)
    issues = report.errors.select { |issue| issue.rule == rule }
    refute_empty issues, "#{fixture}: no #{rule} among #{report.errors.map(&:rule).uniq}"
    assert issues.any? { |issue| issue.message.match?(message) }, "#{fixture}: #{report.errors.map(&:message)}"
  end

  def report_of(fixture)
    validate_template(cdk_template(fixture))
  end
end
