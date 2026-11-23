# frozen_string_literal: true

require "test_helper"

class ErrorsTest < Minitest::Test
  def test_every_deliberate_error_is_a_ruby_cdk_error
    [
      RubyCdk::UsageError, RubyCdk::PreconditionError, RubyCdk::ValidationError, RubyCdk::ChangeSetRejected,
      RubyCdk::ApprovalRefused, RubyCdk::DeploymentFailed, RubyCdk::RulesFailed
    ].each do |klass|
      assert_operator klass, :<, RubyCdk::Error
    end
  end

  def test_a_validation_error_lists_every_issue_at_once
    issues = [
      RubyCdk::Issue.new(rule: "V3", path: "Table.Properties.nmae", message: "is not a property of AWS::DynamoDB::Table", hint: "did you mean KeySchema?"),
      RubyCdk::Issue.new(rule: "V5", path: "Fn.Properties", message: "is missing the required property Code", hint: nil)
    ]
    error = RubyCdk::ValidationError.new(issues)

    assert_equal issues, error.issues
    assert_includes error.message, "V3 Table.Properties.nmae: is not a property of AWS::DynamoDB::Table"
    assert_includes error.message, "V5 Fn.Properties: is missing the required property Code"
  end

  def test_plain_strings_are_accepted_as_issues
    error = RubyCdk::ValidationError.new([ "something is wrong" ])

    assert_equal "something is wrong", error.message
  end
end
