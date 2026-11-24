# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# `ls`: the stacks of the app.
class CliListTest < CliHelpers::TestCase
  TWO_STACKS = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new do |app|
      RubyCdk::Stack.new(app, "network") { resource("Vpc", "AWS::EC2::VPC", properties: { "CidrBlock" => "10.0.0.0/16" }) }
      RubyCdk::Stack.new(app, "web") { resource("Queue", "AWS::SQS::Queue") }
    end
  RUBY
  WITH_ENV = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new(env: RubyCdk::Env.new(account: "#{CliHelpers::ACCOUNT}", region: "#{CliHelpers::REGION}")) do |app|
      RubyCdk::Stack.new(app, "hello") { resource("Queue", "AWS::SQS::Queue") }
    end
  RUBY

  def test_the_stacks_one_per_line_as_in_the_cdk
    write_app(TWO_STACKS)

    result = cli("ls")

    assert_equal 0, result.code
    assert_equal "network\nweb\n", result.out.string
    assert_equal "", result.err.string
  end

  def test_list_is_another_name_for_it
    write_app(ONE_STACK)

    assert_equal "hello\n", cli("list").out.string
  end

  def test_a_name_shows_that_stack_only
    write_app(TWO_STACKS)

    assert_equal "web\n", cli("ls", "web").out.string
    assert_equal "network\nweb\n", cli("ls", "web", "network").out.string
  end

  def test_long_says_where_each_stack_deploys
    write_app(TWO_STACKS)

    assert_equal "network\tno env: it deploys wherever the credentials point\nweb\tno env: it deploys wherever the credentials point\n",
      cli("ls", "--long").out.string

    write_app(WITH_ENV)
    assert_equal "hello\t#{CliHelpers::ACCOUNT}/#{CliHelpers::REGION}\n", cli("ls", "-l").out.string
  end

  def test_json_is_the_same_list_as_one_array
    write_app(WITH_ENV)

    result = cli("ls", "--json")

    assert_equal 0, result.code
    assert_equal [ { "name" => "hello", "env" => { "account" => CliHelpers::ACCOUNT, "region" => CliHelpers::REGION } } ], JSON.parse(result.out.string)
  end

  def test_a_name_that_is_no_stack_s_is_a_usage_error
    write_app(ONE_STACK)

    result = cli("ls", "typo")

    assert_equal 1, result.code
    assert_equal "", result.out.string
    assert_includes result.err.string, "ruby-cdk: No stacks match the name(s) typo\n"
    assert_includes result.err.string, "Run `ruby-cdk ls` without a name to see every stack of the app.\n"
  end

  def test_nothing_is_synthesized
    write_app(ONE_STACK)

    cli("ls")

    refute File.exist?(File.join(dir, "cdk.out")), "the tree exists as soon as the app file ran"
  end
end
