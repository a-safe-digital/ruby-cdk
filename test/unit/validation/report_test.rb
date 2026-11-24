# frozen_string_literal: true

require_relative "support"

# The report: every issue of one validation in one place, with the suggestions and the
# documentation link of the type.
class ValidationReportTest < Minitest::Test
  include ValidationCase

  def test_the_report_says_what_it_found
    report = report_for(fixture("v16-bad-policies"))

    refute_empty report.errors
    assert_empty report.warnings
    refute report.ok?
    assert_equal [ "V16" ], report.by_rule.map { |id, _| id }
    assert_equal 2, report.of_rule("V16").length
    assert_empty report.of_rule("V1")
  end

  def test_a_report_of_warnings_only_passes
    report = report_for(fixture("v15-stateful-delete"))

    assert report.ok?
    assert_equal 1, report.warnings.length
    assert_match(/1 warning/, report.to_s)
    assert_match(/\(warning\)/, report.to_s)
  end

  def test_an_empty_report_passes_and_says_nothing_was_found
    report = report_for(fixture("pass-minimal"))

    assert report.ok?
    assert report.empty?
    assert_equal "Validation passed: nothing to report.\n", report.to_s
  end

  def test_every_error_names_its_rule_its_path_and_its_suggestion
    report = report_for(fixture("v3-typo"))
    issue = report.errors.first

    assert_equal "V3", issue.rule
    assert_match(%r{\AResources\.Table\.Properties\.}, issue.path)
    assert_match(/KeySchema/, issue.message)
    assert_match(/key_schema/, issue.hint)
    assert_match(%r{\AV3  }, report.to_s.lines[1])
  end

  def test_a_resource_carrying_its_documentation_link
    report = report_for(fixture("v3-typo"))
    rows = report.rows

    assert_equal [ "V3", "Resources.Table.Properties.KeySchem", report.errors.first.message, report.errors.first.hint,
      "https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-dynamodb-table.html" ], rows.first
  end

  def test_an_issue_outside_a_resource_carries_no_link
    report = report_for(fixture("v12-description-too-long"))

    assert_nil report.rows.first.last
  end

  def test_the_summary_counts_errors_and_warnings_apart
    template = fixture("v1-unknown-type")
    template["Resources"]["Nameless"] = { "Properties" => {} }
    report = report_for(template)

    assert_equal 1, report.errors.length
    assert_equal 1, report.warnings.length
    assert_match(/1 error and 1 warning/, report.to_s)
    assert_match(/no Type/, report.to_s)
    assert_match(/Custom::Widget/, report.to_s)
  end
end
