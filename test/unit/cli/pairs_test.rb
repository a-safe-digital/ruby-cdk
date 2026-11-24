# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# --parameters and --tags, written as KEY=VALUE pairs.
class CliPairsTest < Minitest::Test
  def parse(text)
    RubyCdk::Cli::Pairs.parse(text, option: "--parameters", command: "deploy")
  end

  def test_pairs_separated_by_commas
    assert_equal({ "a" => "1", "b" => "2" }, parse("a=1,b=2"))
  end

  def test_nothing_given_is_no_pairs
    assert_equal({}, parse(nil))
    assert_equal({}, parse(""))
    assert_equal({}, parse("  "))
  end

  def test_a_value_keeps_its_equals_signs_and_its_spaces
    assert_equal({ "a" => "1=2" }, parse("a=1=2"))
    assert_equal({ "a" => "" }, parse("a="))
  end

  def test_the_space_after_a_comma_is_not_part_of_the_key
    assert_equal({ "a" => "1", "b" => "2" }, parse("a=1, b=2"))
  end

  def test_something_that_is_not_a_pair_is_a_usage_error
    error = assert_raises(RubyCdk::Cli::Usage) { parse("a=1,b") }

    assert_equal "--parameters takes KEY=VALUE pairs separated by commas, and \"b\" is not one", error.message
    assert_equal "Run `ruby-cdk deploy` again with --parameters KEY=VALUE,KEY=VALUE.", error.next_step

    assert_raises(RubyCdk::Cli::Usage) { parse("=1") }
    assert_raises(RubyCdk::Cli::Usage) { parse(",") }
  end

  def test_a_key_given_twice_is_a_usage_error
    error = assert_raises(RubyCdk::Cli::Usage) { parse("a=1,a=2") }

    assert_equal "--parameters names \"a\" twice: \"1\" and \"2\"", error.message
    assert_equal "Run `ruby-cdk deploy` again with a=VALUE once.", error.next_step
  end
end
