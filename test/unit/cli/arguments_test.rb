# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# The words of a command line before Thor reads them.
class CliArgumentsTest < Minitest::Test
  COMMANDS = RubyCdk::CLI.all_commands.keys + RubyCdk::CLI.map.keys

  def first(*words)
    RubyCdk::Cli::Arguments.command_first(words, commands: COMMANDS, switches: RubyCdk::CLI.class_options)
  end

  def test_the_words_are_untouched_when_the_command_is_first
    assert_equal %w[deploy hello --yes], first("deploy", "hello", "--yes")
    assert_equal %w[synth], first("synth")
    assert_equal [], first
  end

  def test_options_before_the_command_move_after_it
    assert_equal %w[synth --quiet], first("--quiet", "synth")
    assert_equal %w[ls --app cdk.rb --quiet], first("--app", "cdk.rb", "--quiet", "ls")
    assert_equal %w[deploy -a cdk.rb hello], first("-a", "cdk.rb", "deploy", "hello")
    assert_equal %w[deploy --app=cdk.rb hello], first("--app=cdk.rb", "deploy", "hello")
  end

  def test_the_value_of_an_option_is_never_taken_for_the_command
    assert_equal %w[deploy --app deploy], first("--app", "deploy", "deploy")
    assert_equal %w[ls --profile sandbox --region deploy], first("--profile", "sandbox", "--region", "deploy", "ls")
  end

  def test_the_help_and_the_version_flags_are_left_alone
    assert_equal %w[--version], first("--version")
    assert_equal %w[-h], first("-h")
    assert_equal %w[--help deploy], first("--help", "deploy")
    assert_equal %w[--version --quiet], first("--quiet", "--version")
  end

  def test_a_word_that_names_no_command_stays_first_for_thor_to_refuse
    assert_equal %w[bogus deploy], first("bogus", "deploy")
    assert_equal %w[-- deploy], first("--", "deploy")
    assert_equal %w[--app], first("--app")
  end

  def test_the_array_given_is_not_changed
    argv = [ "--quiet", "synth" ]

    first(*argv)

    assert_equal [ "--quiet", "synth" ], argv
  end
end
