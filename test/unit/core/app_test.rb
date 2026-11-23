# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# The root: how the command line finds it, and what it holds.
class CoreAppTest < CoreHelpers::TestCase
  def test_current_is_the_only_app_in_the_process
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::App.current }

    assert_match(/There is no RubyCdk::App: the app file creates one with RubyCdk::App.new/, error.message)

    app = build_app

    assert_same app, RubyCdk::App.current

    build_app
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::App.current }

    assert_match(/There are 2 RubyCdk::Apps and none was built by App.build!/, error.message)
  end

  def test_build_loads_the_app_file_and_returns_the_app_it_created
    path = write_app_file(<<~RUBY)
      require "ruby-cdk"

      RubyCdk::App.new(stack_name_prefix: "test-") do |app|
        RubyCdk::Stack.new(app, "one") { resource("Table", "AWS::DynamoDB::Table") }
      end
    RUBY

    app = RubyCdk::App.build!(app_file: path)

    assert_kind_of RubyCdk::App, app
    assert_equal [ "one" ], app.stacks.map(&:id)
    assert_equal "test-one", app.stacks.first.stack_name
    assert_equal "App", app.path
    assert_same app, RubyCdk::App.current
  end

  def test_build_works_again_and_again_in_one_process
    path = write_app_file("RubyCdk::App.new\n")

    first = RubyCdk::App.build!(app_file: path)
    second = RubyCdk::App.build!(app_file: path)

    refute_same first, second
    assert_same second, RubyCdk::App.current
    assert_equal [ first, second ], RubyCdk::App.instances
  end

  def test_only_the_apps_the_file_creates_count
    earlier = build_app
    path = write_app_file("RubyCdk::App.new\n")

    app = RubyCdk::App.build!(app_file: path)

    refute_same earlier, app
    assert_same app, RubyCdk::App.current
    assert_equal [ earlier, app ], RubyCdk::App.instances
  end

  def test_build_refuses_a_file_that_is_not_there
    missing = File.join(dir, "missing", "cdk.rb")

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::App.build!(app_file: missing) }

    assert_equal "There is no app file at #{missing}", error.message
  end

  def test_the_app_file_must_create_exactly_one_app
    none = write_app_file("table = 1\n")

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::App.build!(app_file: none) }

    assert_equal "#{none} created no RubyCdk::App: the app file must create exactly one, with RubyCdk::App.new", error.message

    two = write_app_file("RubyCdk::App.new\nRubyCdk::App.new\n")

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::App.build!(app_file: two) }

    assert_equal "#{two} created 2 RubyCdk::Apps: the app file must create exactly one", error.message
    assert_raises(RubyCdk::UsageError) { RubyCdk::App.current }
  end

  def test_an_error_in_the_app_file_is_reported_at_the_user_s_file_and_line
    path = write_app_file("raise ArgumentError, \"the user's mistake\"\n")

    error = assert_raises(ArgumentError) { RubyCdk::App.build!(app_file: path) }

    assert_equal "the user's mistake", error.message
    assert_equal path, error.backtrace.first.split(":").first
    assert_equal "1", error.backtrace.first.split(":")[1]
    assert_match(/in .*/, error.backtrace.first)
  end

  def test_a_relative_path_is_taken_from_the_working_directory
    write_app_file("RubyCdk::App.new(stack_name_prefix: 'rel-')\n", name: "cdk.rb")

    app = Dir.chdir(dir) { RubyCdk::App.build!(app_file: "cdk.rb") }

    assert_equal "rel-", app.stack_name_prefix
    assert_equal [ app ], RubyCdk::App.instances
  end

  def test_stacks_are_the_stacks_among_the_children_in_the_order_they_were_created
    app = build_app
    RubyCdk::Construct.new(app, "Loose")
    one = RubyCdk::Stack.new(app, "one")
    two = RubyCdk::Stack.new(app, "two")

    assert_equal [ one, two ], app.stacks
    assert_predicate app.stacks, :frozen?
    assert_equal [ "Loose", "one", "two" ], app.children.map(&:id)
    assert_empty build_app.stacks
  end

  def test_the_block_receives_the_app
    seen = nil
    app = RubyCdk::App.new(out_dir: dir) { |built| seen = built }

    assert_same app, seen
  end

  def test_the_app_holds_its_options_and_checks_them
    assert_nil build_app.env
    assert_same TEST_ENV, build_app(env: TEST_ENV).env
    assert_equal "cdk.out", RubyCdk::App.new.out_dir
    assert_nil build_app.stack_name_prefix
    assert_equal :retain_except_on_create, build_app.stateful_default
    assert_equal :delete, build_app(stateful_default: "delete").stateful_default

    assert_raises(RubyCdk::UsageError) { RubyCdk::App.new(env: "eu-west-1") }
    assert_raises(RubyCdk::UsageError) { RubyCdk::App.new(out_dir: "") }
    assert_raises(RubyCdk::UsageError) { RubyCdk::App.new(out_dir: Object.new) }
    assert_raises(RubyCdk::UsageError) { RubyCdk::App.new(stack_name_prefix: :acme) }
    assert_raises(RubyCdk::UsageError) { RubyCdk::App.new(stateful_default: :snapshot) }
  end

  def test_reset_forgets_every_app
    build_app

    RubyCdk::App.reset!

    assert_empty RubyCdk::App.instances
    assert_raises(RubyCdk::UsageError) { RubyCdk::App.current }
  end

  private

  def write_app_file(source, name: "app.rb")
    path = File.join(dir, name)
    File.write(path, source)
    path
  end
end
