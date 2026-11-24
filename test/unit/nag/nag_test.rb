# frozen_string_literal: true

require "test_helper"
require "support/nag_case"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

# The entry points: Nag.check, Nag.check_all, Nag.load_config, Nag.rules.
class NagTest < Minitest::Test
  include NagCase

  Nag = RubyCdk::Nag

  def open_bucket(name)
    [ name, resource("AWS::S3::Bucket", { "BucketName" => name }) ]
  end

  # A template with these resources, each given as [ logical ID, resource ].
  def stack(*resources)
    template(resources.to_h)
  end

  def shut_bucket(name)
    block = { "BlockPublicAcls" => true, "IgnorePublicAcls" => true, "BlockPublicPolicy" => true, "RestrictPublicBuckets" => true }
    [ name, resource("AWS::S3::Bucket", { "BucketName" => name, "PublicAccessBlockConfiguration" => block }) ]
  end

  # --- Nag.check

  def test_check_returns_a_report_on_one_template
    report = check(template({ "Disk" => resource("AWS::EC2::Volume", { "Size" => 10 }) }))

    assert_instance_of Nag::Report, report
    assert_equal [ "Disk" ], hits(report, "RC-EBS-001")
  end

  def test_check_needs_no_configuration_and_then_runs_every_rule
    assert_clean check(template({ "Bucket" => shut_bucket("fine")[1] }))
    assert_equal [ "Bucket" ], hits(check(template({ "Bucket" => open_bucket("open")[1] })), "RC-S3-001")
  end

  def test_check_takes_a_hash_written_like_the_configuration_file
    with_symbol_keys = check_resource("AWS::Logs::LogGroup", {}, config: { rules: { "RC-LOGS-001" => false } })
    with_string_keys = check_resource("AWS::Logs::LogGroup", {}, config: { "rules" => { "RC-LOGS-001" => false } })

    assert_clean with_symbol_keys
    assert_clean with_string_keys
  end

  def test_check_takes_a_config_object
    config = Nag::Config.new(rules: { "RC-LOGS-001" => false })

    assert_clean check_resource("AWS::Logs::LogGroup", {}, config: config)
  end

  def test_check_refuses_a_configuration_that_is_neither
    assert_raises(ArgumentError) { check_resource("AWS::Logs::LogGroup", {}, config: "rules") }
  end

  def test_check_matches_the_path_it_is_given_against_paths_to_suppress
    template = stack(open_bucket("open"))
    config = { "paths_to_suppress" => [ "examples/*" ] }

    assert_equal [ "open" ], hits(check(template, config: config), "RC-S3-001")
    assert_empty check(template, config: config, path: "examples/sandbox.template.json").violations
  end

  # --- Nag.check_all

  def test_check_all_answers_one_report_per_stack_in_the_order_given
    reports = Nag.check_all({ "beta" => stack(open_bucket("b")), "alpha" => stack(shut_bucket("a")) })

    assert_equal [ "beta", "alpha" ], reports.keys
    assert_equal [ "b" ], hits(reports.fetch("beta"), "RC-S3-001")
    assert_clean reports.fetch("alpha")
  end

  def test_check_all_matches_each_stack_name_and_path_against_paths_to_suppress
    templates = { "web-sandbox" => stack(open_bucket("w")), "web-prod" => stack(open_bucket("p")), "jobs" => stack(open_bucket("j")) }
    config = { "paths_to_suppress" => [ "*-sandbox", "examples/legacy/*" ] }

    reports = Nag.check_all(templates, config: config, paths: { "jobs" => "examples/legacy/jobs.template.json" })

    assert_equal 1, suppressed(reports.fetch("web-sandbox")).length
    assert_equal 1, suppressed(reports.fetch("jobs")).length
    assert_equal [ "p" ], hits(reports.fetch("web-prod"), "RC-S3-001")
  end

  def test_check_all_takes_the_same_configuration_as_check
    report = Nag.check_all({ "logs" => stack([ "Log", resource("AWS::Logs::LogGroup") ]) }, config: { "rules" => { "RC-LOGS-001" => false } }).fetch("logs")

    assert_clean report
  end

  def test_check_all_refuses_anything_but_a_hash_of_templates
    [ nil, [], "web" ].each do |argument|
      assert_raises(ArgumentError) { Nag.check_all(argument) }
    end
  end

  # --- nothing a template holds makes a check raise

  def test_check_never_raises_whatever_it_is_given
    templates = [
      nil, "x", 12, [], {},
      { "Resources" => nil }, { "Resources" => [] }, { "Resources" => "x" },
      { "Resources" => { "A" => "x" } }, { "Resources" => { "A" => nil } }, { "Resources" => { "A" => {} } },
      { "Resources" => { "A" => { "Type" => { "Ref" => "SomeParameter" } } } },
      { "Resources" => { "A" => { "Type" => "AWS::S3::Bucket", "Properties" => "oops" } } },
      { "Resources" => { "A" => { "Type" => "AWS::S3::Bucket", "Properties" => { "PublicAccessBlockConfiguration" => 12 }, "Metadata" => 5 } } },
      { "Resources" => { "A" => { "Type" => "AWS::EC2::SecurityGroup", "Properties" => { "SecurityGroupIngress" => { "IpProtocol" => "tcp", "CidrIp" => "0.0.0.0/0" } } } } },
      { "Resources" => { "A" => { "Type" => "AWS::IAM::Role", "Properties" => { "Policies" => [ { "PolicyDocument" => { "Statement" => "oops" } } ] } } } },
      { "Resources" => { "A" => { "Type" => "AWS::KMS::Key", "Properties" => { "KeyPolicy" => "{not json" } } } },
      { "Resources" => { "A" => { "Type" => "AWS::ApiGateway::Method", "Properties" => { "AuthorizationType" => 7 } } } },
      { "Resources" => { "A" => { "Type" => "AWS::RDS::DBInstance", "Properties" => { "StorageEncrypted" => "perhaps", "Engine" => 5 } } } }
    ]
    templates.each do |template|
      report = check(template)

      assert_instance_of Nag::Report, report
      # Whatever could not be read is counted, never hidden.
      report.skipped.each { |skipped| refute_empty skipped.reason }
    end
  end

  def test_a_resource_that_is_no_mapping_or_has_no_type_is_left_alone
    report = check({ "Resources" => { "NotAMapping" => "x", "NoType" => {}, "DynamicType" => { "Type" => { "Ref" => "T" }, "Properties" => { "Encrypted" => false } } } })

    assert_clean report
  end

  def test_a_value_a_rule_cannot_read_is_counted_not_hidden
    report = check(template({ "Disk" => resource("AWS::EC2::Volume", { "Encrypted" => 7 }) }))

    assert_empty report.violations
    assert_equal [ "Disk" ], report.skipped.map(&:logical_id)
    assert_equal "Properties.Encrypted", report.skipped.first.path
    assert_includes report.skipped.first.reason, "not a boolean"
  end

  # --- Nag.load_config, Nag.rules

  def test_load_config_reads_the_file_of_a_project_or_answers_the_default
    Dir.mktmpdir do |root|
      default = Nag.load_config(root)
      assert_equal :medium, default.threshold
      assert_empty default.suppressions

      FileUtils.mkdir_p(File.join(root, ".ruby-cdk"))
      File.write(File.join(root, ".ruby-cdk", "nag.yml"), "threshold: low\n")
      assert_equal :low, Nag.load_config(root).threshold
    end
  end

  def test_rules_lists_the_pack
    assert_equal 15, Nag.rules.length
    assert_equal Nag.rules.map(&:id), Nag.rules.map(&:id).sort
    assert_equal Nag::Rules::ALL, Nag.rules
    assert_equal "0.1", Nag::RULES_VERSION
  end

  def test_the_stateful_types_are_the_list_of_architecture_section_7
    assert_equal %w[
      AWS::S3::Bucket AWS::DynamoDB::Table AWS::Logs::LogGroup AWS::KMS::Key AWS::EC2::Volume AWS::ECR::Repository
      AWS::Cognito::UserPool AWS::Kinesis::Stream AWS::OpenSearchService::Domain AWS::RDS::DBInstance AWS::RDS::DBCluster
    ], Nag::STATEFUL_TYPES
  end

  # --- the component stands alone

  def test_requiring_the_entry_file_loads_the_pack_and_nothing_else_of_the_gem
    lib = File.expand_path("../../../lib", __dir__)
    script = 'require "ruby_cdk/nag"; puts $LOADED_FEATURES.grep(%r{/lib/ruby_cdk}).map { |f| f.sub(%r{.*/lib/}, "") }.sort'
    expected = (Dir[File.join(lib, "ruby_cdk", "nag", "**", "*.rb")] + [ File.join(lib, "ruby_cdk", "nag.rb"), File.join(lib, "ruby_cdk", "errors.rb") ])
      .map { |file| file.delete_prefix("#{lib}/") }.sort

    # A Ruby of its own, with nothing but lib on the load path: no Bundler, so
    # that the gemspec cannot load a file for the component.
    output, error, status = Open3.capture3({ "RUBYOPT" => nil }, RbConfig.ruby, "--disable-gems", "-I", lib, "-e", script)

    assert status.success?, error
    assert_equal expected, output.lines.map(&:chomp)
    assert_equal [ "ruby_cdk/errors.rb" ], output.lines.grep(/ruby_cdk\/[^\/]+\.rb/).map(&:chomp) - [ "ruby_cdk/nag.rb" ]
  end
end
