# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# `validate`: the selection, the report, the exit codes, and --strict-types.
# The rules run for real here: the vendored model is what says what is wrong.
class CliValidateTest < CliHelpers::TestCase
  TWO_STACKS = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new do |app|
      RubyCdk::Stack.new(app, "network") do
        resource("Vpc", "AWS::EC2::VPC", properties: { "CidrBlock" => "10.0.0.0/16" })
      end
      RubyCdk::Stack.new(app, "web") do
        resource("Queue", "AWS::SQS::Queue")
      end
    end
  RUBY
  # A first deploy of a Lambda function cannot work without Code and Role: rule
  # V5 has the model's word for it, and the report is where validate says so.
  BROKEN = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new do |app|
      RubyCdk::Stack.new(app, "web") do
        resource("Function", "AWS::Lambda::Function", properties: {
          "Code" => { "S3Bucket" => "an-asset-bucket", "S3Key" => "function.zip" },
          "Handler" => "app.bootstrap",
          "Runtime" => "ruby3.4"
        })
      end
    end
  RUBY
  # V1: a type no source describes. The template is emitted with a warning,
  # and --strict-types makes the same finding an error.
  UNKNOWN_TYPE = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new do |app|
      RubyCdk::Stack.new(app, "hello") do
        resource("Widget", "AWS::Demo::Widget", properties: { "Name" => "x" })
      end
    end
  RUBY

  # The strict registration is not restored by the command line (a process
  # runs one command), so a test that has run it leaves the default set for the
  # ones that follow: every test starts from the umbrella's own set.
  def setup
    super
    restore_default_validators
  end

  def restore_default_validators
    RubyCdk::App.reset!
    RubyCdk::Synth.validators.each do |validator|
      next if validator.is_a?(RubyCdk::Synth::Rules::LogicalIds) || validator.is_a?(RubyCdk::Synth::Rules::StackName)

      RubyCdk::Synth.unregister_validator(validator)
    end
    RubyCdk::Validation.validators(warnings: true, stateful_types: RubyCdk::Core::Stateful::RETAINED_TYPES + RubyCdk::Core::Stateful::SNAPSHOT_TYPES)
      .each { |validator| RubyCdk::Synth.register_validator(validator) }
  end

  # --- the selection

  def test_validate_of_the_only_stack_is_clean_and_prints_the_report
    write_app(ONE_STACK)

    result = cli("validate")

    assert_equal 0, result.code
    assert_equal "", result.out.string, "nothing on standard out for a person"
    assert_includes result.err.string, "hello\n"
    assert_includes result.err.string, "hello: 0 error(s), 0 warning(s)\n"
  end

  def test_no_name_in_an_app_of_several_stacks_is_the_same_usage_error_as_deploy
    write_app(TWO_STACKS)
    aws = CliHelpers::NoAws.new

    result = cli("validate", aws:)

    assert_equal 1, result.code
    assert_includes result.err.string, "Since this app includes more than a single stack, specify which stacks to use or specify `--all`\n" \
      "Stacks: network · web\n"
    assert result.err.string.end_with?("Run `ruby-cdk validate --all`, or `ruby-cdk validate STACK` for one of them.\n")
  end

  def test_all_validates_every_stack_and_a_name_validates_one
    write_app(TWO_STACKS)

    all = cli("validate", "--all")
    one = cli("validate", "web")

    assert_equal 0, all.code
    assert_includes all.err.string, "network\n"
    assert_includes all.err.string, "web\n"
    assert_equal 0, one.code
    refute_includes one.err.string, "network\n", "the stack not named is not validated"
  end

  def test_a_name_that_is_no_stack_s_is_a_usage_error
    write_app(TWO_STACKS)

    result = cli("validate", "typo")

    assert_equal 1, result.code
    assert_includes result.err.string, "No stacks match the name(s) typo"
    assert_includes result.err.string, "Run `ruby-cdk ls` to see the stacks of the app, then `ruby-cdk validate STACK`.\n"
  end

  # --- the report

  def test_a_rule_failure_is_reported_and_exits_2
    write_app(BROKEN)

    result = cli("validate")

    assert_equal 2, result.code, "architecture section 14: local validation failed"
    assert_equal "", result.out.string
    assert_match(/V5 Resources\.Function\.Properties\.Role: the required property Role is missing/, result.err.string)
    assert_match(/web: 1 error\(s\), 0 warning\(s\)\n/, result.err.string)  end

  def test_the_pipeline_s_own_findings_are_reported_too
    # Two resources of different ids cannot collide, but a Parameter and a
    # Resource can: the tree's V2 reports the duplicate logical ID across
    # sections, and the report names it.
    write_app(ONE_STACK.sub('resource("Queue", "AWS::SQS::Queue")',
      'parameter("Queue", type: "String").tap { resource("Queue", "AWS::SQS::Queue") }'))

    result = cli("validate")

    assert_equal 2, result.code
    assert_match(/V2/, result.err.string)
  end

  def test_nothing_is_written
    write_app(ONE_STACK)

    assert_equal 0, cli("validate").code

    refute File.exist?(File.join(dir, "cdk.out")), "validate writes no files, so there is no cdk.out"
    refute File.exist?(File.join(dir, "hello.template.json"))
  end

  def test_json_is_one_object_per_stack_and_nothing_else_on_standard_out
    write_app(TWO_STACKS)

    result = cli("validate", "--all", "--json")

    assert_equal 0, result.code
    assert_equal 2, result.out.string.lines.size
    network, web = result.records
    assert_equal %w[name exit_code errors warnings], network.keys
    assert_equal "network", network.fetch("name")
    assert_equal 0, network.fetch("exit_code")
    assert_empty network.fetch("errors")
    assert_empty web.fetch("errors")
    assert_equal "", result.err.string.lines.reject { |line| line.start_with?("{") }.join, "the engine says nothing for a clean run"
  end

  def test_json_reports_the_errors_and_exits_2
    write_app(BROKEN)

    result = cli("validate", "--json")

    assert_equal 2, result.code
    record = result.records.first
    assert_equal "web", record.fetch("name")
    assert_equal 2, record.fetch("exit_code")
    error = record.fetch("errors").first
    assert_equal "V5", error.fetch("rule")
    assert_equal "Resources.Function.Properties.Role", error.fetch("path")
    assert_match(/the required property Role is missing/, error.fetch("message"))
  end

  # --- warnings, and --strict-types

  def test_an_unknown_type_is_a_warning_by_default_and_the_run_is_clean
    write_app(UNKNOWN_TYPE)

    result = cli("validate")

    assert_equal 0, result.code, "V1 without --strict-types: the type is emitted with a warning"
    assert_match(/warning V1 Resources\.Widget\.Type: /, result.err.string)
    assert_match(/hello: 0 error\(s\), 1 warning\(s\)\n/, result.err.string)
  end

  def test_strict_types_makes_the_unknown_type_an_error
    write_app(UNKNOWN_TYPE)

    result = cli("validate", "--strict-types")

    assert_equal 2, result.code
    assert_match(/\n  V1 Resources\.Widget\.Type: /, result.err.string, "as an error, not as a warning")
    assert_match(/hello: 1 error\(s\), 0 warning\(s\)\n/, result.err.string)
  end

  def test_strict_types_reaches_the_pipeline_synthesis_too
    # The pipeline is what synth runs; --strict-types re-registered its
    # validators, so a synth in the same process after a strict validate would
    # refuse. The command line re-registers nothing back: one process, one
    # command. What a test can see is that validate ran the strict set, which
    # the previous test pins; this one pins that the flag is validate's own.
    write_app(ONE_STACK)

    synth_takes_it = cli("synth", "--strict-types")

    assert_equal 1, synth_takes_it.code, "synth does not take --strict-types"
    assert_includes synth_takes_it.err.string, "Unknown switches \"--strict-types\""
  end

  # --- warnings are reported and do not fail

  def test_the_report_names_the_rule_s_hint
    write_app(BROKEN)

    result = cli("validate")

    assert_match(%r{add it, as Role or in snake_case as role}, result.err.string)
  end
end
