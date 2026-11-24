# frozen_string_literal: true

require_relative "support"

# The structural rules (architecture §6): V1 to V7 and V12, over the fixtures under
# test/fixtures/validation/templates. V2 and V13 are checked again with the tree's own
# rules in test/unit/synth/rules_test.rb; the cases here are the ones a template with no
# tree behind it goes through.
class ValidationStructureTest < Minitest::Test
  include ValidationCase

  # --- V1

  def test_an_unknown_type_is_a_warning_and_nothing_else_is_checked_of_it
    report = report_for(fixture("v1-unknown-type"))

    assert_equal({ "V1" => 1 }, rules_of(report))
    assert RubyCdk::Validation.warning?(report.warnings.first)
    assert_match(/Custom::Widget/, report.warnings.first.message)
    assert_match(/--strict-types/, report.warnings.first.hint)
  end

  def test_a_resource_with_no_type_at_all_is_an_error
    report = report_for(fixture("v1-no-type"))

    assert_equal({ "V1" => 1 }, rules_of(report))
    refute RubyCdk::Validation.warning?(report.errors.first)
  end

  def test_an_unknown_type_is_an_error_under_strict_types
    report = report_for(fixture("v1-unknown-type"), strict_types: true)

    assert_equal({ "V1" => 1 }, rules_of(report))
    assert_empty report.warnings
    assert_match(/Custom::Widget/, report.errors.first.message)
  end

  # --- V2

  def test_a_logical_id_holds_letters_and_digits_only
    report = report_for(fixture("v2-underscore-id"))

    assert_equal({ "V2" => 1 }, rules_of(report))
    assert_equal "Resources.my_table", report.errors.first.path
    assert_match(/MyTable/, report.errors.first.hint)
  end

  def test_a_parameter_and_a_resource_never_share_one_logical_id
    report = report_for(fixture("v2-name-clash"))

    assert_equal({ "V2" => 1 }, rules_of(report))
    assert_equal "Resources.Stage", report.errors.first.path
    assert_match(/Parameters\.Stage/, report.errors.first.message)
  end

  # --- V3 and V4

  def test_a_property_the_type_does_not_know_is_an_error_with_the_closest_name
    report = report_for(fixture("v3-typo"))

    assert_includes report.errors.map(&:rule), "V3"
    typo = report.errors.find { |issue| issue.path.end_with?("KeySchem") }
    assert_match(/did you mean KeySchema/, typo.message)
    assert_match(/key_schema/, typo.hint)
  end

  def test_a_key_nothing_resolves_to_is_an_error_without_a_suggestion
    report = report_for(fixture("v3-unresolvable-snake"))

    assert_equal({ "V3" => 1 }, rules_of(report))
    assert_equal "Resources.Bucket.Properties.cors_config", report.errors.first.path
    assert_match(/not a property of AWS::S3::Bucket/, report.errors.first.message)
  end

  def test_a_snake_case_key_never_reaches_v4
    report = report_for(fixture("pass-snake-case"))

    assert_empty report.of_rule("V4")
  end

  # --- V5

  def test_a_required_property_missing_at_the_top_is_an_error
    report = report_for(fixture("v5-missing-top"))

    assert_equal({ "V5" => 1 }, rules_of(report))
    assert_equal "Resources.Table.Properties.KeySchema", report.errors.first.path
  end

  def test_a_required_property_missing_inside_a_list_element_is_an_error
    report = report_for(fixture("v5-missing-nested"))

    assert_equal({ "V5" => 1 }, rules_of(report))
    assert_equal "Resources.Bucket.Properties.CorsConfiguration.CorsRules[0].AllowedOrigins", report.errors.first.path
  end

  def test_a_nested_stack_is_not_asked_for_the_stack_name_the_provider_requires
    template = {
      "Resources" => {
        "Nested" => {
          "Type" => "AWS::CloudFormation::Stack",
          "Properties" => { "TemplateBody" => { "Resources" => { "Inner" => { "Type" => "AWS::S3::Bucket" } } } }
        }
      }
    }

    assert_empty report_for(template).of_rule("V5")
  end

  # --- V6 and V17

  def test_a_value_of_another_kind_than_the_property_takes_is_an_error
    report = report_for(fixture("v6-wrong-kind"))

    assert_equal({ "V6" => 1 }, rules_of(report))
    assert_equal "Resources.Func.Properties.Timeout", report.errors.first.path
    assert_match(/a whole number/, report.errors.first.message)
  end

  def test_a_number_written_as_a_string_is_an_error_with_the_hint
    report = report_for(fixture("v17-string-for-number"))

    assert_equal({ "V17" => 1 }, rules_of(report))
    assert_equal "Resources.Table.Properties.ProvisionedThroughput.ReadCapacityUnits", report.errors.first.path
    assert_equal "drop the quotes: write 5", report.errors.first.hint
  end

  def test_a_boolean_written_as_a_string_is_an_error_with_the_hint
    report = report_for(fixture("v17-string-for-boolean"))

    assert_equal({ "V17" => 1 }, rules_of(report))
    assert_equal "drop the quotes: write true", report.errors.first.hint
  end

  def test_a_number_where_a_string_belongs_is_taken_as_the_cdks_include_takes_it
    template = {
      "Resources" => {
        "Bucket" => {
          "Type" => "AWS::S3::Bucket",
          "Properties" => {
            "WebsiteConfiguration" => {
              "RoutingRules" => [ { "RedirectRule" => { "HttpRedirectCode" => 403 } } ]
            }
          }
        }
      }
    }

    assert_empty report_for(template).issues
  end

  # --- V7

  def test_a_list_property_holds_an_array
    report = report_for(fixture("v7-not-a-list"))

    assert_equal({ "V7" => 1 }, rules_of(report))
    assert_equal "Resources.Bucket.Properties.CorsConfiguration.CorsRules", report.errors.first.path
  end

  def test_duplicates_where_each_element_is_taken_once_are_a_warning
    report = report_for(fixture("v7-duplicates"))

    assert_equal({ "V7" => 1 }, rules_of(report))
    assert_empty report.errors
    assert RubyCdk::Validation.warning?(report.warnings.first)
    assert_equal "Resources.Table.Properties.KeySchema", report.warnings.first.path
  end

  # --- V12

  def test_a_logical_id_longer_than_the_cloudformation_allows_is_an_error
    report = report_for(fixture("v12-name-too-long"))

    assert_equal({ "V12" => 1 }, rules_of(report))
    assert_match(/at most 255/, report.errors.first.message)
  end

  def test_a_description_longer_than_the_cloudformation_allows_is_an_error
    report = report_for(fixture("v12-description-too-long"))

    assert_equal({ "V12" => 1 }, rules_of(report))
    assert_equal "Description", report.errors.first.path
    assert_match(/1024/, report.errors.first.message)
  end

  def test_the_quota_of_five_hundred_resources
    resources = (1..501).to_h { |index| [ "R#{index}", { "Type" => "AWS::S3::Bucket" } ] }

    report = report_for({ "Resources" => resources })

    assert_equal({ "V12" => 1 }, rules_of(report))
    assert_match(/501 resources/, report.errors.first.message)
  end

  # --- V13

  def test_a_stack_name_that_cloudformation_rejects_is_an_error
    report = report_for(fixture("pass-minimal"), stack_name: "1blog")

    assert_equal({ "V13" => 1 }, rules_of(report))
    assert_equal "Stack", report.errors.first.path
  end

  def test_a_stack_without_a_name_behind_it_has_nothing_to_check
    template = fixture("pass-minimal")
    context = RubyCdk::Validation::Context.new(stack: nil, template:, issues: [])

    assert_empty RubyCdk::Validation.rule("V13").call(context)
  end

  # --- V16

  def test_a_policy_name_the_cloudformation_does_not_take_is_an_error
    report = report_for(fixture("v16-bad-policies"))

    assert_equal({ "V16" => 2 }, rules_of(report))
    assert_equal [ "Resources.Bucket.DeletionPolicy", "Resources.Bucket.UpdateReplacePolicy" ], report.errors.map(&:path)
    assert_match(/write Retain/, report.errors.last.hint)
  end

  def test_every_literal_branch_of_an_fn_if_policy_is_checked
    report = report_for(fixture("v16-intrinsic-policy"))

    assert_equal({ "V16" => 1 }, rules_of(report))
    assert_equal "Resources.Bucket.DeletionPolicy.Fn::If[2]", report.errors.first.path
  end

  # --- V18

  def test_a_value_outside_the_ones_the_source_lists_is_an_error
    report = report_for(fixture("v18-bad-value"))

    assert_equal({ "V18" => 1 }, rules_of(report))
    assert_equal "Resources.Bucket.Properties.AccessControl", report.errors.first.path
    assert_match(/PublicRead/, report.errors.first.message)
  end

  # --- V19

  def test_a_string_against_the_documented_pattern_is_a_warning
    report = report_for(fixture("v19-pattern"))

    assert_equal({ "V19" => 1 }, rules_of(report))
    assert_empty report.errors
    assert_match(/\[0-9\]\+/, report.warnings.first.message)
  end
end
