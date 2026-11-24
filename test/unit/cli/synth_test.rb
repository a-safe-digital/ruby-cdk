# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"

# `synth`, in process: what it writes, what it prints, and how the app file's
# failures are reported. No client is ever built here.
class CliSynthTest < CliHelpers::TestCase
  TWO_STACKS = <<~RUBY
    require "ruby-cdk"
    RubyCdk::App.new do |app|
      RubyCdk::Stack.new(app, "network") do
        resource("Vpc", "AWS::EC2::VPC", properties: { "CidrBlock" => "10.0.0.0/16" })
      end
      RubyCdk::Stack.new(app, "web") { resource("Queue", "AWS::SQS::Queue") }
    end
  RUBY

  # --- what is written

  def test_synth_writes_the_template_and_the_manifest_and_prints_the_template
    write_app(ONE_STACK)

    result = cli("synth")

    assert_equal 0, result.code
    template = File.binread(File.join(dir, "cdk.out", "hello.template.json"))
    assert_equal template, result.out.string, "the CDK prints the template of the single stack"
    assert_match(/"AWSTemplateFormatVersion": "2010-09-09"/, template)
    assert_match(/\ASynthesis time: \d+\.\d{2}s\n\z/, result.err.string, "the line the CDK prints after a synthesis")
    manifest = JSON.parse(File.read(File.join(dir, "cdk.out", "manifest.json")))
    assert_equal [ "hello" ], manifest.fetch("stacks").map { |stack| stack.fetch("name") }
  end

  def test_out_decides_where_the_templates_go_when_the_app_file_does_not
    write_app(ONE_STACK)

    result = cli("synth", "--out", "build", "--quiet")

    assert_equal 0, result.code
    assert File.file?(File.join(dir, "build", "hello.template.json")), "the option's directory"
    refute File.exist?(File.join(dir, "cdk.out")), "and not the default"
  end

  def test_the_app_file_s_out_dir_wins_over_the_option_as_in_the_cdk
    write_app(ONE_STACK.sub("RubyCdk::App.new", 'RubyCdk::App.new(out_dir: "build")'))

    result = cli("synth", "--out", "elsewhere", "--quiet")

    assert_equal 0, result.code
    assert File.file?(File.join(dir, "build", "hello.template.json")), "the app file's directory"
    refute File.exist?(File.join(dir, "elsewhere")), "and not the option's"
  end

  def test_an_empty_out_is_a_usage_error
    write_app(ONE_STACK)

    result = cli("synth", "--out=")

    assert_equal 1, result.code
    assert_includes result.err.string, "ruby-cdk: --out must not be empty\n"
    assert_includes result.err.string, "Run `ruby-cdk synth` again without --out, or with --out VALUE.\n"
  end

  # --- what is printed

  def test_quiet_prints_no_template
    write_app(ONE_STACK)

    result = cli("synth", "--quiet")

    assert_equal 0, result.code
    assert_equal "", result.out.string
    assert File.file?(File.join(dir, "cdk.out", "hello.template.json")), "the files are still written"
  end

  def test_json_prints_the_manifest_and_nothing_else_on_standard_out
    write_app(TWO_STACKS)

    result = cli("synth", "--json")

    assert_equal 0, result.code
    assert_equal JSON.parse(File.read(File.join(dir, "cdk.out", "manifest.json"))), JSON.parse(result.out.string)
    assert_equal [ "network", "web" ], JSON.parse(result.out.string).fetch("stacks").map { |stack| stack.fetch("name") }
    assert_equal "", result.err.string
  end

  def test_several_stacks_put_nothing_on_standard_out_and_say_why
    write_app(TWO_STACKS)

    result = cli("synth")

    assert_equal 0, result.code
    assert_equal "", result.out.string
    assert_includes result.err.string, "Successfully synthesized to #{File.join(dir, "cdk.out").sub("/var/", "/private/var/")}\n"
    assert_includes result.err.string, "Supply a stack id (network, web) to display its template.\n"
  end

  def test_a_named_stack_has_its_template_printed
    write_app(TWO_STACKS)

    web = cli("synth", "web")
    both = cli("synth", "network", "web")

    assert_equal 0, web.code
    assert_equal File.binread(File.join(dir, "cdk.out", "web.template.json")), web.out.string

    assert_equal "", both.out.string, "several named stacks, like several in the app: nothing on standard out"
  end

  def test_a_name_that_is_no_stack_s_is_a_usage_error_with_nothing_on_standard_out
    write_app(TWO_STACKS)

    result = cli("synth", "web", "--json", "typo")

    assert_equal 1, result.code
    assert_equal "", result.out.string
    assert_includes result.err.string, "ruby-cdk: No stacks match the name(s) typo\n"
    assert_includes result.err.string, "Run `ruby-cdk ls` to see the stacks of the app, then `ruby-cdk synth STACK`.\n"
  end

  def test_verbose_says_what_the_command_decided
    write_app(ONE_STACK)

    result = cli("synth", "--quiet", "--verbose")

    assert_includes result.err.string, "ruby-cdk: loading the app file #{File.join(dir, "cdk.rb").sub("/var/", "/private/var/")}\n"
    assert_match(/ruby-cdk: synthesized 1 stack\(s\) into .*\/cdk\.out\n/, result.err.string)
  end

  # --- exit 2: a rule failed

  def test_a_template_that_fails_a_rule_exits_2_and_names_the_command_to_run_again
    # A stack name must start with a letter (V13): the tree takes the id, and
    # the rule fails at synthesis, where the whole template is known.
    write_app(ONE_STACK.sub('"hello"', '"2bad"'))

    result = cli("synth")

    assert_equal 2, result.code
    assert_match(/V13 .*the stack name "2bad" is not valid/, result.err.string)
    assert result.err.string.end_with?("Correct the template and run `ruby-cdk synth` again.\n")
    assert_equal "", result.out.string
    refute File.exist?(File.join(dir, "cdk.out")), "nothing is written when a rule fails"
  end

  # --- exit 1: the app file

  def test_a_missing_app_file_is_a_usage_error_naming_the_option
    result = cli("synth")

    assert_equal 1, result.code
    assert_match(%r{ruby-cdk: There is no app file at .*/cdk\.rb\n}, result.err.string)
    assert_equal "Run the command from the app's directory, or with --app PATH (the default is cdk.rb).\n", result.err.string.lines.last
  end

  def test_the_app_file_is_named_by_app
    write_app(ONE_STACK, "app/hello.rb")

    missing = cli("synth", "--app", "app/nowhere.rb")
    found = cli("ls", "--app", "app/hello.rb")

    assert_equal 1, missing.code
    assert_equal 0, found.code
    assert_equal "hello\n", found.out.string
  end

  def test_an_error_in_the_app_file_is_reported_at_its_line_without_the_gem_s_backtrace
    write_app("require \"ruby-cdk\"\nRubyCdk::App.new do |app|\n  RubyCdk::Stack.new(app, \"hello\") do\n    buckett\n  end\nend\n")

    plain = cli("synth")
    verbose = cli("synth", "--verbose")

    assert_equal 1, plain.code
    lines = plain.err.string.lines
    assert_match(/\/cdk\.rb: line 4, in '/, lines.first)
    assert_match(/\ANameError: undefined local variable or method .buckett'/, lines[1])
    assert_equal "Correct #{lines.first[/\S*\/cdk\.rb/]} and run `ruby-cdk synth` again.\n", lines.last
    refute_match(/ruby_cdk\//, plain.err.string, "no gem backtrace without --verbose")

    assert_equal 1, verbose.code
    assert_match(/lib\/ruby_cdk\/core\/app\.rb:\d+:in/, verbose.err.string)
  end

  def test_a_syntax_error_in_the_app_file_is_reported_at_its_line
    write_app("require \"ruby-cdk\"\nRubyCdk::App.new do |app|\n")

    result = cli("synth")

    assert_equal 1, result.code
    assert_match(/\/cdk\.rb: line 2, syntax errors found/, result.err.string)
    assert_match(/\nSyntaxError: .*\/cdk\.rb:2: syntax errors found/, result.err.string)
  end

  def test_a_library_the_app_file_needs_and_lacks_is_reported_at_its_line
    write_app("require \"no-such-library-for-the-ruby-cdk-tests\"\n")

    result = cli("synth")

    assert_equal 1, result.code
    assert_match(/\/cdk\.rb: line 1/, result.err.string)
    assert_match(/LoadError: cannot load such file -- no-such-library-for-the-ruby-cdk-tests/, result.err.string)
  end

  def test_an_error_of_the_gem_raised_by_the_app_file_is_placed_at_its_line_too
    write_app("require \"ruby-cdk\"\nRubyCdk::App.new do |app|\n  RubyCdk::Stack.new(app, \"bad id!\")\nend\n")

    result = cli("synth")

    assert_equal 1, result.code
    assert_includes result.err.string, "The id \"bad id!\" under App is not valid"
    assert_match(/^    at .*\/cdk\.rb: line 3, in '/, result.err.string)
    refute_match(/lib\/ruby_cdk\//, result.err.string)
  end

  def test_the_app_file_must_create_exactly_one_app
    none = cli("synth", "--app", write_app("require \"ruby-cdk\"\n"))
    two = cli("synth", "--app", write_app("require \"ruby-cdk\"\nRubyCdk::App.new\nRubyCdk::App.new\n", "two.rb"))

    assert_equal 1, none.code
    assert_includes none.err.string, "created no RubyCdk::App: the app file must create exactly one"
    assert_equal 1, two.code
    assert_includes two.err.string, "created 2 RubyCdk::Apps: the app file must create exactly one"
  end

  def test_a_closed_standard_out_is_not_a_failure
    closed = Object.new
    closed.define_singleton_method(:print) { |*| raise Errno::EPIPE }
    closed.define_singleton_method(:puts) { |*| raise Errno::EPIPE }
    write_app(ONE_STACK)
    Dir.chdir(dir) do
      code = RubyCdk::CLI.run([ "synth" ], io: RubyCdk::Cli::Io.new(out: closed, err: StringIO.new, stdin: StringIO.new))

      assert_equal 0, code, "as `ruby-cdk synth | head` ends when head is done"
    end
  end
end
