# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# Which stacks a command acts on, and in what order: the CDK's rules.
class CliSelectionTest < Minitest::Test
  Stack = Data.define(:stack_name)
  Entry = Data.define(:name, :dependencies)

  def choose(stacks, names: [], all: false)
    RubyCdk::Cli::Selection.choose(stacks.map { |name| Stack.new(name) }, names:, all:, command: "deploy")
  end

  def order(entries, selected, direction: :up, exclusively: false)
    RubyCdk::Cli::Selection.ordered(entries.map { |name, dependencies| Entry.new(name:, dependencies:) }, selected:, direction:, exclusively:)
      .map(&:name)
  end

  def usage
    assert_raises(RubyCdk::Cli::Usage) { yield }
  end

  # --- which stacks

  def test_no_name_is_the_only_stack_of_the_app
    assert_equal %w[hello], choose(%w[hello]).map(&:stack_name)
  end

  def test_no_name_in_an_app_of_several_stacks_is_an_error_in_the_cdk_s_words
    error = usage { choose(%w[network web]) }

    assert_equal "Since this app includes more than a single stack, specify which stacks to use or specify `--all`\nStacks: network · web",
      error.message
    assert_equal "Run `ruby-cdk deploy --all`, or `ruby-cdk deploy STACK` for one of them.", error.next_step
  end

  def test_no_name_in_an_app_of_no_stack_is_an_error
    error = usage { choose([]) }

    assert_equal "This app contains no stacks", error.message
    assert_equal "Run `ruby-cdk deploy --all`, or `ruby-cdk deploy STACK` for one of them.", error.next_step
  end

  def test_all_is_every_stack
    assert_equal %w[network web], choose(%w[network web], all: true).map(&:stack_name)
    assert_equal %w[hello], choose(%w[hello], all: true).map(&:stack_name)
  end

  def test_all_with_a_name_is_an_error_as_in_the_cdk
    error = usage { choose(%w[network web], names: %w[web], all: true) }

    assert_equal "You must either specify a list of Stacks or the `--all` argument", error.message
    assert_equal "Run `ruby-cdk deploy web`, or `ruby-cdk deploy --all`.", error.next_step
  end

  def test_names_are_the_stacks_in_the_app_s_order
    assert_equal %w[network web], choose(%w[network web], names: %w[web network]).map(&:stack_name)
  end

  def test_a_name_that_is_no_stack_s_is_an_error
    error = usage { choose(%w[network web], names: %w[typo]) }
    assert_equal "No stacks match the name(s) typo", error.message
    assert_equal "Run `ruby-cdk ls` to see the stacks of the app, then `ruby-cdk deploy STACK`.", error.next_step
  end

  def test_a_name_that_is_no_stack_s_is_an_error_even_beside_one_that_matches
    error = usage { choose(%w[network web], names: %w[web typo]) }

    assert_equal "No stacks match the name(s) typo", error.message
  end

  # --- the order

  def test_a_deploy_goes_dependencies_first_whatever_the_app_s_order
    assert_equal %w[network web], order({ "web" => %w[network], "network" => [] }, %w[web network])
    assert_equal %w[a b c d], order({ "d" => %w[b c], "b" => %w[a], "c" => %w[a], "a" => [] }, %w[a b c d])
  end

  def test_a_named_stack_brings_what_it_depends_on
    assert_equal %w[network web], order({ "network" => [], "web" => %w[network] }, %w[web])
    assert_equal %w[a b c], order({ "a" => [], "b" => %w[a], "c" => %w[b] }, %w[c])
  end

  def test_exclusively_leaves_the_dependencies_alone
    assert_equal %w[web], order({ "network" => [], "web" => %w[network] }, %w[web], exclusively: true)
  end

  def test_a_destroy_goes_dependents_first
    assert_equal %w[web network], order({ "network" => [], "web" => %w[network] }, %w[network web], direction: :down)
  end

  def test_a_named_destroy_brings_what_depends_on_it
    assert_equal %w[c b network], order({ "network" => [], "b" => %w[network], "c" => %w[b] }, %w[network], direction: :down)
    assert_equal %w[network], order({ "network" => [], "b" => %w[network] }, %w[network], direction: :down, exclusively: true)
  end

  def test_a_circle_of_dependencies_is_an_error_that_names_it
    error = usage { order({ "network" => %w[web], "web" => %w[network] }, %w[network web]) }

    assert_equal "The stacks depend on each other in a circle: network -> web -> network", error.message
  end
end
