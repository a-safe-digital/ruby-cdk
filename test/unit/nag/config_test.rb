# frozen_string_literal: true

require "test_helper"
require "support/nag_case"
require "fileutils"
require "tmpdir"

# .ruby-cdk/nag.yml: what it may say, what is refused, and how it suppresses.
class NagConfigTest < Minitest::Test
  include NagCase

  def open_bucket(name = "open")
    [ name, resource("AWS::S3::Bucket", { "BucketName" => name }) ]
  end

  def write_config(root, text)
    FileUtils.mkdir_p(File.join(root, ".ruby-cdk"))
    File.write(File.join(root, ".ruby-cdk", "nag.yml"), text)
  end

  def load(text, path: "nag.yml")
    RubyCdk::Nag::Config.from_file(write_temporary(text, path))
  end

  def write_temporary(text, name)
    file = File.join(Dir.mktmpdir, name)
    File.write(file, text)
    file
  end

  # --- what a file may say

  def test_an_absent_or_empty_file_is_the_default
    Dir.mktmpdir do |root|
      assert_equal RubyCdk::Nag::Config.default, RubyCdk::Nag::Config.load(root)
      write_config(root, "")
      config = RubyCdk::Nag::Config.load(root)

      assert_equal :medium, config.threshold
      assert_empty config.suppressions
      assert_empty config.paths_to_suppress
      assert_empty config.warnings
    end
  end

  def test_the_file_sets_the_threshold
    assert_equal :low, load("threshold: low").threshold
    assert_equal :high, load("threshold: high").threshold
    assert_equal :medium, load("threshold: medium").threshold
    assert_equal :medium, load("").threshold
  end

  def test_the_file_turns_rules_off
    config = load("rules:\n  RC-LOGS-001: false\n  RC-EBS-001: false\n")

    refute config.rule_enabled?("RC-LOGS-001")
    refute config.rule_enabled?("RC-EBS-001")
    assert config.rule_enabled?("RC-S3-001")

    log_group = check_resource("AWS::Logs::LogGroup", {}, config: config)
    disk = check_resource("AWS::EC2::Volume", { "Size" => 1 }, config: config)
    bucket = check_resource("AWS::S3::Bucket", { "BucketName" => "b" }, config: config)

    assert_empty log_group.violations
    assert_empty disk.violations
    assert_equal [ "Only" ], hits(bucket, "RC-S3-001"), "a rule that is not named runs"
  end

  def test_the_file_names_the_stateful_types
    config = load("stateful_types:\n  - AWS::Example::Thing\n")

    assert_equal [ "AWS::Example::Thing" ], config.stateful_types
    assert_one_violation(check_resource("AWS::Example::Thing", {}, config: config, deletion_policy: "Delete"),
      "RC-STATE-001", severity: :high, resource_type: "AWS::Example::Thing", path: "DeletionPolicy", says: [ "Delete" ])
    assert_empty violations(check_resource("AWS::S3::Bucket", { "PublicAccessBlockConfiguration" => {
      "BlockPublicAcls" => true, "IgnorePublicAcls" => true, "BlockPublicPolicy" => true, "RestrictPublicBuckets" => true
    } }, config: config, deletion_policy: "Delete"), "RC-STATE-001")
  end

  def test_paths_to_suppress_is_a_list_of_globs
    config = load("paths_to_suppress:\n  - \"*-sandbox\"\n  - \"examples/legacy/*\"\n")

    refute_nil config.suppressed_path([ "web-sandbox", "web-sandbox.template.json" ])
    refute_nil config.suppressed_path([ "prod", "examples/legacy/prod.template.json" ])
    assert_nil config.suppressed_path([ "prod", "prod.template.json" ])
    assert_nil config.suppressed_path([])
  end

  # --- the suppression written in the file

  def test_a_suppression_covers_the_resource_by_id_and_by_type
    config = load(<<~YAML)
      suppressions:
        - id: RC-S3-001
          reason: The bucket is the public website.
          applies_to: "Web*"
        - id: RC-EC2-001
          reason: Every security group of this stack reaches the internet through the load balancer.
          applies_to: "AWS::EC2::*"
    YAML

    assert_equal "The bucket is the public website.", config.suppression_for("RC-S3-001", "WebService", "AWS::S3::Bucket")&.reason
    assert_nil config.suppression_for("RC-S3-001", "DataBucket", "AWS::S3::Bucket"), "the glob names the logical ID"
    assert_equal "Every security group of this stack reaches the internet through the load balancer.",
      config.suppression_for("RC-EC2-001", "sg", "AWS::EC2::SecurityGroup")&.reason
    assert_nil config.suppression_for("RC-EC2-001", "sg", "AWS::SQS::Queue")
    assert_nil config.suppression_for("RC-EBS-001", "WebService", "AWS::EC2::Volume"), "no suppression is written for that rule"
  end

  def test_a_suppression_without_a_reason_is_ignored_with_a_warning
    config = load(<<~YAML)
      suppressions:
        - id: RC-S3-001
        - id: RC-EBS-001
          reason: " "
        - id: RC-EBS-001
          reason: Encrypted in the account by default.
    YAML

    assert_equal 2, config.warnings.length
    assert_includes config.warnings.first.message, "RC-S3-001"
    assert_includes config.warnings.last.message, "RC-EBS-001"
    assert_includes config.warnings.first.message, "without a reason"
    # The entry with the reason is the one that stands.
    assert_equal 1, config.suppressions.length
    assert_equal "Encrypted in the account by default.", config.suppressions.first.reason
  end

  def test_the_warnings_reach_the_report
    bucket, web = open_bucket("Web")
    report = check(template(bucket => web), config: { suppressions: [ { "id" => "RC-S3-001" } ] })

    assert_equal [ "Web" ], hits(report, "RC-S3-001"), "the suppression is ignored"
    assert_equal 1, report.warnings.length
    assert_includes report.warnings.first.message, "without a reason"
  end

  # --- a suppression of the file and one of the resource, in one report

  def test_both_kinds_of_suppression_hold_in_one_report
    bucket, web = open_bucket("Web")
    closed = { "BlockPublicAcls" => true, "IgnorePublicAcls" => true, "BlockPublicPolicy" => true, "RestrictPublicBuckets" => true }
    config = { suppressions: [ { "id" => "RC-S3-001", "reason" => "The whole stack is public by design.", "applies_to" => "Web*" } ] }
    template_with_metadata = template(
      bucket => resource("AWS::S3::Bucket", { "BucketName" => "web" }, **rules_to_suppress({ "Id" => "RC-S3-001", "Reason" => "This one is on the resource." })),
      "Data" => resource("AWS::S3::Bucket", { "BucketName" => "data", "PublicAccessBlockConfiguration" => closed })
    )

    report = check(template_with_metadata, config: config)

    assert_empty report.violations
    # Web carries its own suppression; where it has one, the file's does not double it.
    # Data is a clean bucket and has nothing to suppress.
    assert_equal 1, report.suppressed.length
    assert_equal "This one is on the resource.", report.suppressed.first.reason
    assert_equal "Web", report.suppressed.first.logical_id

    # Without the resource's own suppression, the file's covers the same finding.
    file_only = check(template({ bucket => resource("AWS::S3::Bucket", { "BucketName" => "web" }) }), config: config)

    assert_empty file_only.violations
    assert_equal "The whole stack is public by design.", suppressed(file_only, "RC-S3-001").first.reason
  end

  def test_a_suppressed_finding_still_names_what_would_have_been_reported
    report = check_resource("AWS::EC2::Volume", { "Encrypted" => false }, **rules_to_suppress({ "Id" => "RC-EBS-001", "Reason" => "Scratch." }))
    entry = assert_suppressed(report, "RC-EBS-001", reason: "Scratch.")

    assert_equal :high, entry.severity
    assert_equal "AWS::EC2::Volume", entry.resource_type
    assert_equal "Properties.Encrypted", entry.path
    assert_includes entry.message, "set Encrypted to true"
  end

  # --- what is refused

  def test_an_unknown_key_is_refused
    error = assert_raises(RubyCdk::Nag::ConfigError) { load("treshold: low") }

    assert_includes error.message, "treshold"
    assert_includes error.message, ":threshold"
  end

  def test_a_threshold_that_is_not_one_of_the_three_is_refused
    [ "threshold: critical", "threshold: [ low ]" ].each do |text|
      error = assert_raises(RubyCdk::Nag::ConfigError) { load(text) }

      assert_includes error.message, "threshold"
    end
    # Case does not matter, and neither does a stray space.
    assert_equal :high, load("threshold: HIGH ").threshold
  end

  def test_a_rule_id_no_rule_has_is_refused
    assert_raises(RubyCdk::Nag::ConfigError) { load("rules:\n  RC-LOGS-999: false\n") }
    assert_raises(RubyCdk::Nag::ConfigError) { load("suppressions:\n  - id: F16\n    reason: x\n") }
    error = assert_raises(RubyCdk::Nag::ConfigError) { load("rules:\n  RC-LOGS-001: maybe\n") }

    assert_includes error.message, "maybe"
  end

  def test_a_suppression_of_the_wrong_shape_is_refused
    assert_raises(RubyCdk::Nag::ConfigError) { load("suppressions:\n  - id: RC-EBS-001\n    reason: x\n    nonsense: y\n") }
    assert_raises(RubyCdk::Nag::ConfigError) { load("suppressions: 12\n") }
    assert_raises(RubyCdk::Nag::ConfigError) { load("suppressions:\n  - reason: no id\n") }
  end

  def test_stateful_types_of_the_wrong_shape_is_refused
    assert_raises(RubyCdk::Nag::ConfigError) { load("stateful_types:\n  - Bucket\n") }
    assert_raises(RubyCdk::Nag::ConfigError) { load("stateful_types: AWS::S3::Bucket\n") }
  end

  def test_yaml_that_does_not_parse_is_refused
    error = assert_raises(RubyCdk::Nag::ConfigError) { load("threshold: [ low\n") }

    assert_includes error.message, "not valid YAML"
  end

  def test_a_file_that_is_not_a_mapping_is_refused
    error = assert_raises(RubyCdk::Nag::ConfigError) { load("- a\n- b\n") }

    assert_includes error.message, "must hold the keys"
  end

  def test_an_unreadable_file_is_refused
    Dir.mktmpdir do |root|
      path = File.join(root, "nag.yml")
      FileUtils.mkdir_p(path)

      error = assert_raises(RubyCdk::Nag::ConfigError) { RubyCdk::Nag::Config.from_file(path) }

      assert_includes error.message, "cannot be read"
    end
  end

  # --- the shape the code can be given

  def test_coerce_takes_a_config_a_hash_or_nothing
    config = RubyCdk::Nag::Config.new(threshold: :low)

    assert_same config, RubyCdk::Nag::Config.coerce(config)
    assert_equal RubyCdk::Nag::Config.default, RubyCdk::Nag::Config.coerce(nil)
    assert_equal :low, RubyCdk::Nag::Config.coerce({ "threshold" => "low" }).threshold
    assert_raises(ArgumentError) { RubyCdk::Nag::Config.coerce("low") }
  end

  def test_a_grown_project_file_keeps_its_path_for_the_messages
    Dir.mktmpdir do |root|
      write_config(root, "treshold: low\n")

      error = assert_raises(RubyCdk::Nag::ConfigError) { RubyCdk::Nag::Config.load(root) }

      assert_includes error.message, File.join(root, ".ruby-cdk", "nag.yml")
    end
  end
end
