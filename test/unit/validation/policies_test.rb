# frozen_string_literal: true

require_relative "support"

# V15 (a stateful type deleted with the stack) and V23 (intrinsics inside the creation
# and update policies), which stand in files of their own.
class ValidationPoliciesTest < Minitest::Test
  include ValidationCase

  # --- V15

  def test_a_stateful_type_deleted_with_the_stack_is_a_warning
    report = report_for(fixture("v15-stateful-delete"))

    assert_equal({ "V15" => 1 }, rules_of(report))
    assert_empty report.errors
    assert RubyCdk::Validation.warning?(report.warnings.first)
    assert_equal "Resources.Bucket.DeletionPolicy", report.warnings.first.path
  end

  def test_a_stateful_type_retained_is_not_reported
    template = fixture("v15-stateful-delete")
    template["Resources"]["Bucket"]["DeletionPolicy"] = "RetainExceptOnCreate"

    assert_empty report_for(template).of_rule("V15")
  end

  def test_a_stateless_type_deleted_is_not_reported
    template = {
      "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue", "DeletionPolicy" => "Delete" } }
    }

    assert_empty report_for(template).of_rule("V15")
  end

  def test_an_fn_if_that_can_resolve_to_delete_is_reported
    template = {
      "Conditions" => { "Cheap" => { "Fn::Equals" => [ "a", "a" ] } },
      "Resources" => {
        "Bucket" => {
          "Type" => "AWS::S3::Bucket",
          "DeletionPolicy" => { "Fn::If" => [ "Cheap", "Delete", "Retain" ] }
        }
      }
    }

    assert_equal({ "V15" => 1 }, rules_of(report_for(template)))
  end

  # --- V23

  def test_an_intrinsic_where_a_policy_takes_an_object_is_an_error_as_the_cdk_says_it
    report = report_for(fixture("v23-intrinsic-policy"))

    assert_equal({ "V23" => 1 }, rules_of(report))
    assert_equal "Resources.Group.UpdatePolicy.AutoScalingRollingUpdate", report.errors.first.path
    assert_match(/string, a number or a boolean/, report.errors.first.message)
  end

  def test_an_intrinsic_in_a_leaf_of_a_policy_is_taken_as_the_cdk_takes_it
    template = {
      "Parameters" => { "Count" => { "Type" => "Number", "Default" => 1 } },
      "Resources" => {
        "Bucket" => {
          "Type" => "AWS::S3::Bucket",
          "CreationPolicy" => {
            "ResourceSignal" => { "Count" => { "Ref" => "Count" }, "Timeout" => "PT5M" }
          }
        }
      }
    }

    assert_empty report_for(template).of_rule("V23")
  end

  def test_each_section_of_each_policy_is_checked
    template = {
      "Conditions" => { "IsProd" => { "Fn::Equals" => [ "a", "a" ] } },
      "Resources" => {
        "Group" => {
          "Type" => "AWS::AutoScaling::AutoScalingGroup",
          "Properties" => { "MinSize" => 1, "MaxSize" => 2 },
          "CreationPolicy" => { "AutoScalingCreationPolicy" => { "Fn::If" => [ "IsProd", {}, {} ] } },
          "UpdatePolicy" => { "AutoScalingScheduledAction" => { "Fn::If" => [ "IsProd", {}, {} ] } }
        }
      }
    }

    report = report_for(template)

    assert_equal({ "V23" => 2 }, rules_of(report))
    assert_equal [
      "Resources.Group.CreationPolicy.AutoScalingCreationPolicy",
      "Resources.Group.UpdatePolicy.AutoScalingScheduledAction"
    ], report.errors.map(&:path)
  end
end
