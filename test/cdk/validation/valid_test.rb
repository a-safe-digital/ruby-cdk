# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/cloudformation-include/test/valid-templates.test.ts
#           (the checks it tests: cloudformation-include/lib/cfn-include.ts over the
#           generated L1 classes, and the acknowledged rules of its engine, listed in
#           test/test-warnings.ts of that package)
#   Commit: 68b2516c09791d78b199f30e455e4670dc9cde6d (aws/aws-cdk, main)
#   Licence: Apache-2.0
#
#   Cases: 82 in the original. 56 ported, 26 not ported.
#
#   Not ported, with the reason. Most of the file is about what the CDK does with a
#   template after it has read it - the include's own API - and none of that exists
#   here; what a case proves about the template being accepted is kept, the rest is
#   listed:
#   - getResource, getParameter, getCondition, getMapping, getOutput, getRule and
#     getHook, and the throwing cases for names that are not there (7 cases)
#   - changing a property, a parameter, a condition, an output or a mapping of an
#     ingested template, and reflecting the change in the synthesized template
#     (5 cases)
#   - overrideLogicalId, with preserveLogicalIds true and false, and the re-naming of
#     references that follows (5 cases)
#   - parameters passed to the include and substituted in Ref, Fn::Sub, CreationPolicy
#     and the sections outside Resources, with their throwing cases (9 cases)
#   - referring to an ingested resource from another stack (2 cases)
#   - Fn.sub of a parameter substituted with a deploy-time value (1 case)
#   - output mutation through `output.value =` (1 case)
#
#   Changed, with nothing else in a scenario, an input or an outcome:
#   - The CDK asserts the template comes out unchanged; this tool never rewrites one,
#     so a case here asserts what its rules say, and a template the CDK accepted is
#     accepted.
#   - "accepts strings for properties with type number" is asserted as the difference
#     architecture section 21 records: rule V17 refuses what the CDK converts.
#   - "can ingest a template that contains properties not in the current CFN spec" is
#     asserted as the engine itself reports it: F3002 there, rule V3 here.
#   - "throws an exception when a custom resource uses a Condition attribute that
#     doesn't exist" is a refusal that lives in this file in the CDK; it is ported
#     as rule V11.
#   - The CDK acknowledges warnings of its own engine to let its fixtures through
#     (test-warnings.ts acknowledges 30 rule ids); the warnings this tool gives on the
#     same fixtures - V1 for a type it does not know, V15 for a stateful resource
#     deleted with the stack - are its rules working, and no case asserts their
#     absence.
#
# Parity: 82 cases in the origin; 56 ported; 26 not ported.

require "json"
require_relative "fixtures"

# The CDK's valid templates, over this tool's rules.
class CdkValidationValidTest < Minitest::Test
  include ValidationFixtures

  # --- a template the CDK accepts is accepted

  def test_a_template_with_only_an_empty_s3_bucket
    assert_accepted "only-empty-bucket"
  end

  def test_a_template_with_an_s3_bucket_with_complex_properties
    assert_accepted "only-bucket-complex-props"
  end

  def test_a_bucket_ref_erencing_a_kms_key
    assert_accepted "bucket-with-encryption-key"
  end

  def test_a_template_with_parameters
    assert_accepted "bucket-with-parameters"
  end

  def test_a_number_for_a_property_with_type_string_is_accepted_as_the_cdks_include_accepts_it
    assert_accepted "number-for-string"
  end

  def test_a_boolean_for_a_property_with_type_string_is_accepted_as_the_cdks_include_accepts_it
    # The CDK acknowledges the warning of its own engine (W3030) to accept this; this
    # tool says nothing: CloudFormation takes the boolean as its text.
    assert_accepted "boolean-for-string"
  end

  def test_an_fn_if_expression_for_simple_values
    assert_accepted "if-simple-property"
  end

  def test_an_fn_if_expression_for_complex_values
    assert_accepted "if-complex-property"
  end

  def test_fn_if_in_tags
    assert_accepted "if-in-tags"
  end

  def test_fn_if_as_the_tags_property
    assert_accepted "if-tags-property"
  end

  def test_a_user_data_script
    assert_accepted "user-data"
  end

  def test_a_property_of_type_map_of_lists_of_primitive_types
    assert_accepted "ssm-association"
  end

  def test_intrinsic_functions_and_conditions
    assert_accepted "functions-and-conditions"
  end

  def test_lambda_layers_defined_with_an_fn_if_condition
    assert_accepted "lambda-layers-with-condition"
  end

  def test_an_fn_if_used_in_the_deletion_policy
    assert_accepted "intrinsic-deletion-policy"
  end

  def test_a_ref_used_in_the_deletion_policy
    assert_accepted "intrinsic-deletion-policy-ref"
  end

  def test_string_form_fn_get_att
    assert_accepted "get-att-string-form"
  end

  def test_fn_sub_in_string_form_with_escaped_and_unescaped_references
    assert_accepted "fn-sub-string"
  end

  def test_the_string_argument_of_fn_sub_with_escaped_references_that_hold_whitespace
    assert_accepted "fn-sub-escaping"
  end

  def test_fn_sub_with_dotted_attributes_in_map_form
    assert_accepted "fn-sub-map-dotted-attributes"
  end

  def test_an_empty_map_passed_to_fn_sub
    assert_accepted "fn-sub-map-empty"
  end

  def test_fn_sub_shadowing_a_logical_id_of_the_template
    assert_accepted "fn-sub-shadow"
  end

  def test_fn_sub_shadowing_a_logical_id_with_an_attribute
    assert_accepted "fn-sub-shadow-attribute"
  end

  def test_a_parameter_shadowed_by_the_map_of_fn_sub
    assert_accepted "fn-sub-shadow-parameter"
  end

  def test_fn_sub_with_brace_edge_cases
    assert_accepted "fn-sub-brace-edges"
  end

  def test_a_ref_expression_for_an_array_value
    assert_accepted "ref-array-property"
  end

  def test_the_sections_outside_resources_render_as_they_were_written
    assert_accepted "only-empty-bucket-with-parameters"
  end

  def test_depends_on_with_a_single_string_value
    assert_accepted "resource-attribute-depends-on"
  end

  def test_depends_on_with_an_array_of_values
    assert_accepted "resource-attribute-depends-on-array"
  end

  def test_conditions_and_the_condition_resource_attribute
    assert_accepted "resource-attribute-condition"
  end

  def test_conditions_that_reference_mappings
    assert_accepted "condition-using-mapping"
  end

  def test_a_condition_and_a_resource_of_one_name
    assert_accepted "condition-same-name-as-resource"
  end

  def test_intrinsics_in_the_leaf_nodes_of_an_autoscaling_creation_policy
    assert_accepted "intrinsics-create-policy-autoscaling"
  end

  def test_nested_intrinsics_in_the_leaf_nodes_of_an_autoscaling_creation_policy
    assert_accepted "intrinsics-create-policy-complex"
  end

  def test_intrinsics_in_the_leaf_nodes_of_a_resource_signal_creation_policy
    assert_accepted "intrinsics-create-policy-resource-signal"
  end

  def test_intrinsics_in_the_leaf_nodes_of_an_autoscaling_rolling_update_policy
    assert_accepted "intrinsics-update-policy-autoscaling-rolling-update"
  end

  def test_every_property_of_an_autoscaling_rolling_update
    assert_accepted "autoscaling-rolling-update-all-properties"
  end

  def test_intrinsics_in_the_leaf_nodes_of_an_autoscaling_replacing_update_policy
    assert_accepted "intrinsics-update-policy-autoscaling-replacing-update"
  end

  def test_intrinsics_in_the_leaf_nodes_of_an_autoscaling_scheduled_action_policy
    assert_accepted "intrinsics-update-policy-autoscaling-scheduled-action"
  end

  def test_intrinsics_in_the_leaf_nodes_of_a_code_deploy_lambda_alias_update_policy
    assert_accepted "intrinsics-update-policy-code-deploy-lambda-alias-update"
  end

  def test_nested_intrinsics_in_the_leaf_nodes_of_an_autoscaling_rolling_update_policy
    assert_accepted "intrinsics-update-policy-complex"
  end

  def test_unknown_resource_attributes
    assert_accepted "non-existent-resource-attribute"
  end

  def test_unknown_policy_attributes
    assert_accepted "non-existent-policy-attribute"
  end

  def test_string_arrays_in_policy_attributes
    assert_accepted "string-arrays-in-policy"
  end

  def test_a_custom_resource_that_uses_attributes
    assert_accepted "custom-resource-with-attributes"
  end

  def test_a_template_with_outputs
    assert_accepted "outputs-with-references"
  end

  def test_a_template_with_a_mapping
    assert_accepted "only-mapping-and-bucket"
  end

  def test_fn_find_in_map_with_a_dynamic_first_argument
    assert_accepted "find-in-map-with-dynamic-mapping"
  end

  def test_fn_find_in_map_for_the_value_of_a_boolean_property
    assert_accepted "find-in-map-for-boolean-property"
  end

  def test_a_template_with_rules
    assert_accepted "only-parameters-and-rule"
  end

  def test_a_template_with_hooks
    assert_accepted "hook-code-deploy-blue-green-ecs"
  end

  def test_an_fn_select_with_an_fn_if_and_a_ref_to_no_value_in_it
    assert_accepted "fn-select-with-novalue"
  end

  def test_fn_if_inside_the_tags_list
    assert_accepted "tags-with-intrinsics"
  end

  # --- the differences, asserted where they are

  def test_a_string_for_a_property_with_type_number_is_refused_by_design
    # architecture section 21: the CDK converts it; here it is rule V17 with the hint.
    report = report_of("string-for-number")

    assert_equal({ "V17" => 1 }, report.errors.map(&:rule).tally)
    assert_equal "Resources.Bucket.Properties.CorsConfiguration.CorsRules[0].MaxAge", report.errors.first.path
    assert_equal "drop the quotes: write 10", report.errors.first.hint
  end

  def test_properties_not_in_the_current_spec_are_reported_as_the_cdks_engine_reports_them
    # The include preserves them (asserted there); the engine behind it reports F3002,
    # which the CDK's own test acknowledges (test-warnings.ts). Rule V3 is this tool's
    # F3002, and it is not acknowledged.
    report = report_of("properties-not-in-cfn-spec")

    assert_equal({ "V3" => 3 }, report.errors.map(&:rule).tally)
    assert report.errors.all? { |issue| issue.message.include?("PropertyNotInCfnSchema") }
  end

  def test_a_custom_resource_with_a_condition_that_does_not_exist_is_refused
    # A refusal that lives in this file in the CDK; rule V11 here.
    report = report_of("custom-resource-with-bad-condition")

    assert_equal({ "V11" => 1 }, report.errors.map(&:rule).tally)
    assert_match(/AlwaysFalseCond/, report.errors.first.message)
  end

  private

  def assert_accepted(fixture)
    report = report_of(fixture)

    assert_empty report.errors, "#{fixture}: #{report.errors.map { |issue| "#{issue.rule} #{issue.path}: #{issue.message}" }}"
  end

  def report_of(fixture)
    validate_template(cdk_template(fixture))
  end
end
