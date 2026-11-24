# frozen_string_literal: true

require "ruby_cdk/nag"

# Shared by the tests of the rule pack: short ways to write a template and to
# read a report, so that a test says what the template holds and what was
# found, and nothing else.
module NagCase
  private

  # A resource as the serializer writes it. Keywords become the resource's
  # attributes with their CloudFormation names: deletion_policy: "Delete" is
  # "DeletionPolicy", metadata: { ... } is "Metadata".
  def resource(type, properties = nil, **attributes)
    attributes.transform_keys! { |key| key.to_s.split("_").map(&:capitalize).join }
    attributes["Type"] = type
    attributes["Properties"] = properties if properties
    attributes
  end

  # A template that holds these resources: template(Bucket => bucket, Disk => disk)
  def template(resources)
    { "Resources" => resources }
  end

  # Checks one resource of a type, on its own, and returns the Report.
  def check_resource(type, properties = {}, config: nil, **attributes)
    check(template({ "Only" => resource(type, properties, **attributes) }), config: config)
  end

  def check(template, config: nil, **options)
    RubyCdk::Nag.check(template, config: config, **options)
  end

  # The logical IDs on which the rule reported.
  def hits(report, rule)
    report.violations.select { |violation| violation.rule == rule }.map(&:logical_id)
  end

  # The violations of the rule.
  def violations(report, rule)
    report.violations.select { |violation| violation.rule == rule }
  end

  # The paths of the checks of the rule that could not be decided.
  def undecided(report, rule)
    report.skipped.select { |skipped| skipped.rule == rule }.map(&:path)
  end

  # What a suppression covered, for one rule or for all of them.
  def suppressed(report, rule = nil)
    report.suppressed.select { |entry| rule.nil? || entry.rule == rule }
  end

  # Nothing was found: no violation, nothing left undecided, nothing suppressed, no warning.
  def assert_clean(report)
    found = report.violations.map { |violation| "#{violation.rule} #{violation.logical_id} #{violation.path}: #{violation.message}" }
    assert_empty report.violations, "expected no violation, found #{found.inspect}"
    assert_empty report.skipped, "expected nothing left undecided, found #{report.skipped.map(&:reason).inspect}"
    assert_empty report.suppressed
    assert_empty report.warnings
  end

  # The report holds exactly these findings, and nothing else: the violations
  # of each rule on each logical ID, and how many checks of each rule were left
  # undecided. expected: { "RC-..." => [ "LogicalId", ... ] }. left: { "RC-..." => 2 }.
  def assert_findings(report, expected, left: {})
    found = report.violations.group_by(&:rule).transform_values { |violations| violations.map(&:logical_id) }
    assert_equal expected.transform_values(&:sort), found.transform_values(&:sort)
    assert_equal left, report.skipped.group_by(&:rule).transform_values(&:length)
    assert_empty report.suppressed
    assert_empty report.warnings
  end

  # The rule reported once, on this resource, at this path, with this
  # severity, and its message says each of these things. Returns the violation.
  def assert_one_violation(report, rule, severity:, resource_type:, path:, says:, logical_id: "Only")
    found = violations(report, rule)
    assert_equal 1, found.length, "expected one #{rule} violation, found #{found.length}: #{found.map(&:message).inspect}"
    violation = found.first
    assert_equal [ rule, severity, logical_id, resource_type, path ], [ violation.rule, violation.severity, violation.logical_id, violation.resource_type, violation.path ]
    says.each { |words| assert_includes violation.message, words, "#{rule} should say #{words.inspect}" }
    violation
  end

  # The rule's check was left undecided once, at this path, and nothing of the rule was reported.
  def assert_undecided(report, rule, path:)
    assert_empty violations(report, rule)
    assert_equal [ path ], undecided(report, rule)
    report.skipped.find { |skipped| skipped.rule == rule }
  end

  # A suppression covered the rule's finding, for this reason, and nothing of
  # the rule is reported as a violation. Returns what was suppressed.
  def assert_suppressed(report, rule, reason:)
    assert_empty violations(report, rule)
    found = suppressed(report, rule)
    assert_equal 1, found.length, "expected one suppressed #{rule} finding, found #{found.length}"
    assert_equal reason, found.first.reason
    assert_equal rule, found.first.rule
    refute report.fails?(:low), "a suppressed finding fails no threshold"
    found.first
  end

  # The suppression this tool reads, written as it is written on a resource.
  def rules_to_suppress(*entries)
    { metadata: { "RubyCdk::Nag" => { "RulesToSuppress" => entries } } }
  end
end
