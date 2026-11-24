# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# The edge of the command line: the version, the exit, and what a usage error
# looks like.
class CliTest < CliHelpers::TestCase
  def test_version_prints_the_gem_version
    result = cli("version")

    assert_equal 0, result.code
    assert_equal "#{RubyCdk::VERSION}\n", result.out.string
    assert_equal "", result.err.string
  end

  def test_version_flag_prints_the_gem_version
    result = cli("--version")

    assert_equal 0, result.code
    assert_equal "#{RubyCdk::VERSION}\n", result.out.string
  end

  def test_the_short_v_is_verbose_as_in_the_cdk_and_not_the_version
    alone = cli("-v")
    with_a_command = cli("version", "-v")

    assert_equal 1, alone.code, "only an option was given, so no command was"
    assert_match(/ruby-cdk commands:/, alone.out.string)
    assert_equal 0, with_a_command.code
  end

  def test_run_answers_a_code_and_does_not_exit
    io = RubyCdk::Cli::Io.new(out: StringIO.new, err: StringIO.new, stdin: StringIO.new)

    assert_equal 0, RubyCdk::CLI.run([ "version" ], io:)
    assert_equal 1, RubyCdk::CLI.run([ "bogus" ], io:)
  end

  def test_main_exits_with_the_command_s_code
    succeeded = assert_raises(SystemExit) { capture_io { RubyCdk::CLI.main([ "version" ]) } }
    failed = assert_raises(SystemExit) { capture_io { RubyCdk::CLI.main([ "bogus" ]) } }

    assert_equal 0, succeeded.status
    assert_equal 1, failed.status
  end

  # --- usage errors: exit 1, and the command to run next

  def test_no_command_prints_the_help_and_is_a_usage_error
    result = cli

    assert_equal 1, result.code, "as the CDK's demandCommand(1): a bare invocation is not a command"
    assert_match(/^ruby-cdk commands:/, result.out.string)
    assert_match(/ruby-cdk deploy \[STACK\.\.\.\]/, result.out.string)
    assert_equal "Run `ruby-cdk help COMMAND` to read about a command, for example `ruby-cdk help deploy`.\n", result.err.string
  end

  def test_only_options_and_no_command_is_the_help_and_a_usage_error
    result = cli("--verbose", "--quiet")

    assert_equal 1, result.code
    assert_match(/^ruby-cdk commands:/, result.out.string)
    assert_match(/Run `ruby-cdk help COMMAND`/, result.err.string)
  end

  def test_help_is_not_an_error
    [ [ "--help" ], [ "help" ], [ "-h" ], [ "help", "deploy" ], [ "help", "ls" ] ].each do |words|
      result = cli(*words)

      assert_equal 0, result.code, words.join(" ")
      assert_match(/^Usage:|^ruby-cdk commands:/, result.out.string)
    end
  end

  def test_the_help_of_one_command_shows_its_own_options_and_the_global_ones
    deploy = cli("help", "deploy")

    assert_equal 0, deploy.code
    assert_match(/--outputs-file/, deploy.out.string)
    assert_match(/--no-execute/, deploy.out.string)
    assert_match(/--on-failure/, deploy.out.string)
    assert_match(/--parameters/, deploy.out.string)
    assert_match(/--tags/, deploy.out.string)
    assert_match(/--all/, deploy.out.string)
    assert_match(/\[--app=APP\]/, deploy.out.string)
    assert_match(/\[--out=OUT\]/, deploy.out.string)
    assert_match(/--profile/, deploy.out.string)
    assert_match(/--region/, deploy.out.string)
    assert_match(/--account/, deploy.out.string)

    synth = cli("help", "synth")
    refute_match(/--outputs-file|--no-execute|--on-failure|--parameters/, synth.out.string)

    destroy = cli("help", "destroy")
    assert_match(/--all/, destroy.out.string)
    refute_match(/--outputs-file|--no-execute|--parameters/, destroy.out.string)
  end

  def test_an_unknown_command_is_a_usage_error_naming_the_help
    result = cli("bogus")

    assert_equal 1, result.code
    assert_equal "", result.out.string
    assert_includes result.err.string, "ruby-cdk: Could not find command \"bogus\".\n"
    assert_includes result.err.string, "Run `ruby-cdk help` to see what the commands are.\n"
  end

  def test_an_unknown_option_is_a_usage_error_naming_the_command_s_help
    result = cli("version", "--bogus")

    assert_equal 1, result.code
    assert_equal "", result.out.string
    assert_includes result.err.string, "Unknown switches \"--bogus\""
    assert_includes result.err.string, "Run `ruby-cdk help version` to see what it takes.\n"
  end

  def test_the_option_of_another_command_is_unknown
    result = cli("synth", "--no-execute")

    assert_equal 1, result.code
    assert_includes result.err.string, "Unknown switches \"--no-execute\""
    assert_includes result.err.string, "Run `ruby-cdk help synth` to see what it takes.\n"
  end

  def test_an_option_may_come_before_the_command_as_the_cdk_writes_it
    write_app(ONE_STACK)

    result = cli("--app", "cdk.rb", "--quiet", "ls")

    assert_equal 0, result.code
    assert_equal "hello\n", result.out.string
  end

  def test_the_help_of_a_command_that_does_not_exist_points_at_the_list
    result = cli("help", "bogus")

    assert_equal 1, result.code
    assert_includes result.err.string, "Could not find command \"bogus\""
    assert_includes result.err.string, "Run `ruby-cdk help` to see what the commands are.\n"
  end

  # --- colour, as the CDK decides it (cli.ts:74-83): --no-color, then --color, then a terminal

  def test_colour_only_when_allowed_and_standard_out_is_a_terminal
    write_app(ONE_STACK)

    refute_includes cli("synth", "nope").err.string, "\e[", "no terminal, no colour"
    assert_includes cli("synth", "nope", terminal: true).err.string, "\e[31m", "a terminal has colour"
    refute_includes cli("synth", "nope", "--no-color", terminal: true).err.string, "\e[", "--no-color wins over a terminal"
    assert_includes cli("synth", "nope", "--color").err.string, "\e[31m", "--color forces it without a terminal"
    refute_includes cli("synth", "nope", "--color", "--no-color", terminal: true).err.string, "\e[", "--no-color wins over --color"
  end

  def test_nothing_the_command_line_prints_through_thor_carries_colour
    refute_includes cli("bogus", "--color", terminal: true).err.string, "\e["
    refute_includes cli("--help", "--color", terminal: true).out.string, "\e["
  end

  # --- a failure the command line does not know

  def test_a_failure_nobody_expected_is_reported_as_a_bug_without_the_gem_s_backtrace
    write_app(ONE_STACK)

    plain = cli("deploy", *unattended)
    verbose = cli("deploy", "--verbose", *unattended)

    assert_equal 1, plain.code
    assert_includes plain.err.string, "ruby-cdk: CliHelpers::NoAws::Asked: the command asked the adapters for a region"
    assert_includes plain.err.string, "Report it as a bug in ruby-cdk, with the command and this output.\n"
    refute_match(/lib\/ruby_cdk\//, plain.err.string)

    assert_equal 1, verbose.code
    assert_match(/cli\/session\.rb:\d+:in/, verbose.err.string)
  end
end
