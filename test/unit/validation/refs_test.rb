# frozen_string_literal: true

require_relative "support"

# The rules over what a template refers to (architecture §6): V8 to V11, V14, V20, V21
# and V22. Each follows a check the CDK's own include makes, and the message follows the
# one the CDK gives.
class ValidationRefsTest < Minitest::Test
  include ValidationCase

  # --- V8

  def test_a_ref_to_something_that_is_not_there_is_an_error_as_the_cdk_says_it
    report = report_for(fixture("v8-ref-missing"))

    assert_equal({ "V8" => 1 }, rules_of(report))
    assert_equal "Resources.Bucket.Properties.BucketName", report.errors.first.path
    assert_match(/DoesNotExist/, report.errors.first.message)
  end

  def test_a_ref_reaches_a_resource_a_parameter_and_a_pseudo_parameter
    report = report_for(fixture("v8-pass-refs"))

    assert_empty report.of_rule("V8")
  end

  def test_a_ref_in_the_conditions_section_reaches_parameters_only
    template = {
      "Parameters" => { "Stage" => { "Type" => "String" } },
      "Conditions" => { "IsProd" => { "Fn::Equals" => [ { "Ref" => "Stage" }, "prod" ] } },
      "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" } }
    }

    assert_empty report_for(template).of_rule("V8")

    template["Conditions"]["IsProd"] = { "Fn::Equals" => [ { "Ref" => "Bucket" }, "prod" ] }
    report = report_for(template)

    assert_equal({ "V8" => 1 }, rules_of(report))
    assert_match(/a parameter or a pseudo-parameter/, report.errors.first.message)
  end

  # --- V9

  def test_an_attribute_the_type_does_not_return_is_an_error
    report = report_for(fixture("v9-attribute-missing"))

    assert_equal({ "V9" => 1 }, rules_of(report))
    assert_match(/Nope/, report.errors.first.message)
    assert_match(/docs\.aws\.amazon\.com/, report.errors.first.hint)
  end

  def test_an_attribute_below_a_read_only_one_is_taken
    report = report_for(fixture("v9-pass-attribute"))

    assert_empty report.of_rule("V9")
  end

  def test_a_custom_resource_and_an_open_type_are_not_checked
    template = {
      "Resources" => {
        "Nested" => {
          "Type" => "AWS::CloudFormation::Stack",
          "Properties" => { "TemplateBody" => { "Resources" => { "I" => { "Type" => "AWS::S3::Bucket" } } } }
        },
        "Reader" => {
          "Type" => "AWS::S3::Bucket",
          "Properties" => { "BucketName" => { "Fn::GetAtt" => [ "Nested", "Outputs.Key" ] } }
        }
      }
    }

    assert_empty report_for(template).of_rule("V9")

    template["Resources"]["Reader"]["Properties"] = { "BucketName" => { "Fn::GetAtt" => [ "Custom", "Whatever" ] } }
    template["Resources"]["Custom"] = { "Type" => "Custom::Thing" }

    assert_empty report_for(template).of_rule("V9")
  end

  def test_an_attribute_the_corpus_proved_the_model_short_of_is_taken
    template = {
      "Resources" => {
        "Recipe" => { "Type" => "AWS::ImageBuilder::ContainerRecipe" },
        "Reader" => {
          "Type" => "AWS::S3::Bucket",
          "Properties" => { "BucketName" => { "Fn::GetAtt" => [ "Recipe", "Version" ] } }
        }
      }
    }

    assert_empty report_for(template).of_rule("V9")
  end

  # --- V10

  def test_a_substitution_variable_that_names_nothing_is_an_error_as_the_cdk_says_it
    report = report_for(fixture("v10-sub-missing"))

    assert_equal({ "V10" => 1 }, rules_of(report))
    assert_equal "Resources.Bucket.Properties.BucketName", report.errors.first.path
    assert_match(/Nowhere/, report.errors.first.message)
  end

  def test_a_variable_the_map_supplies_is_taken
    report = report_for(fixture("v10-sub-supplied"))

    assert_empty report.of_rule("V10")
  end

  def test_a_dotted_variable_names_the_resource_before_the_dot
    template = {
      "Resources" => {
        "One" => { "Type" => "AWS::S3::Bucket" },
        "Two" => {
          "Type" => "AWS::S3::Bucket",
          "Properties" => { "BucketName" => { "Fn::Sub" => "${One.DomainName}" } }
        }
      }
    }

    assert_empty report_for(template).of_rule("V10")
  end

  # --- V11

  def test_a_dependency_on_something_that_is_not_a_resource_is_an_error_as_the_cdk_says_it
    report = report_for(fixture("v11-depends-on-missing"))

    assert_equal({ "V11" => 1 }, rules_of(report))
    assert_equal "Resources.Two.DependsOn[0]", report.errors.first.path
    assert_match(/Nowhere/, report.errors.first.message)
  end

  def test_every_condition_a_template_can_name_a_condition_from_is_checked
    report = report_for(fixture("v11-condition-missing"))

    assert_equal({ "V11" => 3 }, rules_of(report))
    assert_equal [
      "Resources.Bucket.Condition",
      "Outputs.Name.Condition",
      "Resources.Bucket.Properties.BucketName.Fn::If[0]"
    ], report.errors.map(&:path)
  end

  def test_the_mapping_of_an_fn_find_in_map_exists
    report = report_for(fixture("v11-find-in-map"))

    assert_equal({ "V11" => 1 }, rules_of(report))
    assert_equal "Resources.Bucket.Properties.BucketName", report.errors.first.path
    assert_match(/NotThisMap/, report.errors.first.message)
  end

  # --- V14

  def test_a_cycle_is_an_error_as_the_cdk_says_it
    report = report_for(fixture("v14-cycle"))

    assert_equal({ "V14" => 1 }, rules_of(report))
    assert_equal "Found a cycle between resources in the template: One depends on Two depends on One", report.errors.first.message
  end

  def test_every_cycle_in_a_template_is_answered
    template = JSON.parse(File.read(File.expand_path("../../fixtures/validation/cdk/test-templates/invalid/multi-cycle-in-resources.json", __dir__)))
    report = report_for(template)

    assert_equal({ "V14" => 2 }, rules_of(report))
    messages = report.errors.map(&:message)
    assert messages.any? { |message| message.end_with?("Bucket2 depends on Bucket3 depends on Bucket4 depends on Bucket2") }
    assert messages.any? { |message| message.end_with?("Bucket2 depends on Bucket3 depends on Bucket1") }
  end

  def test_a_policy_name_that_happens_to_be_its_own_logical_id_is_no_cycle
    name = "ThePolicy"
    template = {
      "Resources" => {
        "Role" => { "Type" => "AWS::IAM::Role", "Properties" => { "AssumeRolePolicyDocument" => { "Version" => "2012-10-17" } } },
        name => {
          "Type" => "AWS::IAM::Policy",
          "Properties" => { "PolicyName" => name, "Roles" => [ { "Ref" => "Role" } ] }
        }
      }
    }

    assert_empty report_for(template).of_rule("V14")
  end

  # --- V20 to V22

  def test_an_empty_substitution_is_an_error
    report = report_for(fixture("v20-empty-sub"))

    assert_equal({ "V20" => 1 }, rules_of(report))
    assert_match(/"\$\{\}"/, report.errors.first.message)
  end

  def test_a_short_form_getatt_without_a_dot_is_an_error_as_the_cdk_says_it
    report = report_for(fixture("v21-getatt-no-dot"))

    assert_equal({ "V21" => 1 }, rules_of(report))
    assert_equal "the short form of Fn::GetAtt must contain a \".\" in its string argument, got: \"One\"", report.errors.first.message
  end

  def test_a_getatt_of_the_list_form_takes_two_names
    template = {
      "Resources" => {
        "One" => { "Type" => "AWS::S3::Bucket" },
        "Two" => {
          "Type" => "AWS::S3::Bucket",
          "Properties" => { "BucketName" => { "Fn::GetAtt" => [ "One" ] } }
        }
      }
    }

    assert_equal({ "V21" => 1 }, rules_of(report_for(template)))
  end

  def test_a_getatt_in_the_conditions_section_is_an_error_as_the_cdk_says_it
    report = report_for(fixture("v22-getatt-in-conditions"))

    assert_equal({ "V22" => 1 }, rules_of(report))
    assert_equal "Conditions.IsProd.Fn::Equals[0]", report.errors.first.path
  end
end
