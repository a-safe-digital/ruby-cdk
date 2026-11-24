# frozen_string_literal: true

require "test_helper"
require "support/nag_case"

# A report, and the one question a caller asks of it: does it fail the threshold?
class NagReportTest < Minitest::Test
  Report = RubyCdk::Nag::Report
  Violation = RubyCdk::Nag::Violation
  Skipped = RubyCdk::Nag::Skipped
  Suppressed = RubyCdk::Nag::Suppressed
  Warning = RubyCdk::Nag::Warning

  def violation(severity, rule: "RC-X-001")
    Violation.new(rule: rule, severity: severity, logical_id: "Only", resource_type: "AWS::X::Y", path: "Properties.A", message: "change it")
  end

  def report(*severities)
    Report.new(violations: severities.map { |severity| violation(severity) })
  end

  # --- the three thresholds

  def test_the_high_threshold_fails_only_on_a_high_violation
    refute report().fails?(:high)
    refute report(:low, :low).fails?(:high)
    refute report(:medium, :low, :medium).fails?(:high)
    assert report(:medium, :high, :low).fails?(:high)
  end

  def test_the_medium_threshold_fails_on_a_medium_or_a_high_violation
    refute report().fails?(:medium)
    refute report(:low).fails?(:medium)
    assert report(:medium).fails?(:medium)
    assert report(:high).fails?(:medium)
    assert report(:low, :low, :medium).fails?(:medium)
  end

  def test_the_low_threshold_fails_on_any_violation
    refute report().fails?(:low)
    assert report(:low).fails?(:low)
    assert report(:medium).fails?(:low)
    assert report(:high).fails?(:low)
  end

  def test_a_threshold_that_is_not_one_of_the_three_is_a_programming_error
    [ :critical, "medium", nil ].each do |threshold|
      error = assert_raises(ArgumentError) { report(:low).fails?(threshold) }

      assert_includes error.message, ":high, :medium, :low"
    end
  end

  # --- what else a report answers

  def test_worst_severity_is_the_most_serious_violation
    assert_nil report().worst_severity
    assert_equal :low, report(:low, :low).worst_severity
    assert_equal :medium, report(:low, :medium).worst_severity
    assert_equal :high, report(:low, :high, :medium).worst_severity
  end

  def test_by_rule_groups_the_violations
    report = Report.new(violations: [ violation(:high, rule: "RC-A-001"), violation(:low, rule: "RC-B-001"), violation(:low, rule: "RC-A-001") ])

    assert_equal [ "RC-A-001", "RC-B-001" ], report.by_rule.keys
    assert_equal 2, report.by_rule.fetch("RC-A-001").length
  end

  def test_skipped_count_is_the_number_of_checks_that_could_not_be_decided
    skipped = [ Skipped.new(rule: "RC-A-001", logical_id: "Only", resource_type: "AWS::X::Y", path: "Properties.A", reason: "is a Ref") ]
    report = Report.new(skipped: [ skipped.first, skipped.first ])

    assert_equal 2, report.skipped_count
  end

  def test_a_report_is_empty_when_it_holds_nothing
    assert Report.new.empty?

    refute Report.new(violations: [ violation(:low) ]).empty?
    refute Report.new(skipped: [ Skipped.new(rule: "RC-A-001", logical_id: "Only", resource_type: "AWS::X::Y", path: "Properties.A", reason: "r") ]).empty?
    refute Report.new(suppressed: [ Suppressed.new(rule: "RC-A-001", severity: :low, logical_id: "Only", resource_type: "AWS::X::Y", path: "p", message: "m", reason: "why") ]).empty?
    refute Report.new(warnings: [ Warning.new(location: "l", message: "m") ]).empty?
  end

  def test_merge_holds_what_each_report_holds
    suppressed = Suppressed.new(rule: "RC-A-001", severity: :low, logical_id: "Only", resource_type: "AWS::X::Y", path: "p", message: "m", reason: "why")
    warning = Warning.new(location: "l", message: "m")
    skipped = Skipped.new(rule: "RC-A-001", logical_id: "Only", resource_type: "AWS::X::Y", path: "Properties.A", reason: "r")
    first = Report.new(violations: [ violation(:low) ], suppressed: [ suppressed ])
    second = Report.new(violations: [ violation(:high) ], skipped: [ skipped ], warnings: [ warning ])

    merged = Report.merge([ first, second ])

    assert_equal [ :low, :high ], merged.violations.map(&:severity)
    assert_equal [ suppressed ], merged.suppressed
    assert_equal [ skipped ], merged.skipped
    assert_equal [ warning ], merged.warnings
    assert merged.fails?(:high)
    assert Report.merge([]).empty?
  end

  def test_a_suppressed_violation_is_not_one_that_fails_the_threshold
    entry = Suppressed.new(rule: "RC-A-001", severity: :high, logical_id: "Only", resource_type: "AWS::X::Y", path: "p", message: "m", reason: "why")

    refute Report.new(suppressed: [ entry ]).fails?(:low)
  end

  def test_a_report_cannot_be_changed_after_it_is_made
    violations = [ violation(:high) ]
    report = Report.new(violations: violations)
    violations << violation(:low)

    assert_equal 1, report.violations.length
    assert report.violations.frozen?
    assert report.skipped.frozen?
    assert report.suppressed.frozen?
    assert report.warnings.frozen?
  end
end
