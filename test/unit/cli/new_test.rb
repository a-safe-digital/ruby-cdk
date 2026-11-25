# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"
require "ruby_cdk/test"

# `new`, in process: the scaffold the command writes, what it refuses, and
# that everything it writes synthesizes through the real pipeline and passes
# the test kit. No process is started: the generator is a method called here,
# writing into the test's own directory, and App.build! loads the generated
# app file in this process. Every run goes through the helper's default aws:,
# which raises if a client is ever asked for: `new` needs no AWS, no emulator
# and no installed gem.
class CliNewTest < CliHelpers::TestCase
  NAME = "my-app"

  # The generated stack's whole template, as the pipeline must write it.
  EXPECTED_TEMPLATE = {
    "AWSTemplateFormatVersion" => "2010-09-09",
    "Parameters" => {
      "Versioning" => {
        "Type" => "String",
        "Default" => "Suspended",
        "Description" => "Whether the bucket keeps every version of an object",
        "AllowedValues" => [ "Suspended", "Enabled" ]
      }
    },
    "Resources" => {
      "Bucket" => {
        "Type" => "AWS::S3::Bucket",
        "DeletionPolicy" => "RetainExceptOnCreate",
        "UpdateReplacePolicy" => "Retain",
        "Properties" => {
          "BucketEncryption" => {
            "ServerSideEncryptionConfiguration" => [
              { "ServerSideEncryptionByDefault" => { "SSEAlgorithm" => "AES256" } }
            ]
          },
          "PublicAccessBlockConfiguration" => {
            "BlockPublicAcls" => true,
            "BlockPublicPolicy" => true,
            "IgnorePublicAcls" => true,
            "RestrictPublicBuckets" => true
          },
          "VersioningConfiguration" => { "Status" => { "Ref" => "Versioning" } }
        }
      }
    }
  }.freeze

  def test_new_scaffolds_the_project_into_a_directory_it_creates
    result = cli("new", NAME)

    assert_equal 0, result.code
    assert_equal [ ".gitattributes", ".gitignore", "Gemfile", "README.md", "cdk.rb", "my_app" ],
      Dir.children(project_dir).sort
    assert_equal [ "my_app_stack.rb" ], Dir.children(File.join(project_dir, "my_app"))
    assert_includes result.err.string, "Applying project template app for ruby into my-app/"
    assert_includes result.err.string, "bundle install --local"
    assert_includes result.err.string, "All done!"
    assert_includes result.err.string, "# my-app", "the generated README is printed, as the CDK prints it"
  end

  def test_the_generated_app_file_is_one_app_and_one_stack
    cli("new", NAME)

    app = File.read(File.join(project_dir, "cdk.rb"))
    assert_includes app, 'require_relative "my_app/my_app_stack"'
    assert_includes app, "RubyCdk::App.new do |app|", "exactly one App, created in the app file"
    assert_includes app, 'MyApp::Stack.new(app, "my-app")'
    assert_includes app, "RubyCdk::Env.new", "the way to pin an env is written next to where it belongs"

    stack = File.read(File.join(project_dir, "my_app", "my_app_stack.rb"))
    assert_includes stack, "module MyApp"
    assert_includes stack, "class Stack < RubyCdk::Stack"
    assert_includes stack, 'parameter("Versioning"'
    assert_includes stack, 'resource("Bucket", "AWS::S3::Bucket"'
    assert_includes stack, '"RestrictPublicBuckets" => true'
  end

  def test_the_git_files_carry_the_rules_this_tool_depends_on
    cli("new", NAME)

    assert_includes File.read(File.join(project_dir, ".gitattributes")), "* text=auto eol=lf",
      "line endings change an asset's hash (architecture section 8)"
    assert_equal "cdk.out/\n.bundle/\nvendor/\n", File.read(File.join(project_dir, ".gitignore"))
  end

  def test_the_gemfile_pins_the_version_this_machine_runs
    cli("new", NAME)

    gemfile = File.read(File.join(project_dir, "Gemfile"))
    assert_includes gemfile, 'source "https://rubygems.org"'
    assert_includes gemfile, "gem \"ruby-cdk\", \"~> #{RubyCdk::VERSION}\"",
      "the version the scaffold runs with, resolved from the installed gem until a release exists"
  end

  # --- everything generated synthesizes, byte for byte

  def test_the_generated_project_synthesizes_through_the_real_pipeline
    cli("new", NAME)

    manifest = nil
    bytes = Dir.chdir(project_dir) do
      RubyCdk::App.reset!
      app = RubyCdk::App.build!(app_file: "cdk.rb")
      manifest = app.synth
      File.binread(File.join(manifest.out_dir, manifest.entries.first.template))
    end

    assert_equal [ "my-app" ], manifest.entries.map(&:name)
    assert_equal EXPECTED_TEMPLATE, JSON.parse(bytes)
  end

  def test_two_synthses_of_the_generated_project_are_byte_identical
    cli("new", NAME)

    synths = 2.times.map do
      Dir.chdir(project_dir) do
        RubyCdk::App.reset!
        app = RubyCdk::App.build!(app_file: "cdk.rb")
        manifest = app.synth
        File.binread(File.join(manifest.out_dir, manifest.entries.first.template))
      end
    end

    assert_equal synths.first, synths.last, "the same files synthesize to the same bytes"
  end

  def test_the_generated_stack_passes_the_test_kit
    cli("new", NAME)

    app = Dir.chdir(project_dir) do
      RubyCdk::App.reset!
      RubyCdk::App.build!(app_file: "cdk.rb")
    end
    template = RubyCdk::Test.template(app.stacks.first)

    template.resource_count_is("AWS::S3::Bucket", 1)
    template.has_resource_properties("AWS::S3::Bucket", {
      "PublicAccessBlockConfiguration" => RubyCdk::Test.object_equals(
        "BlockPublicAcls" => true,
        "BlockPublicPolicy" => true,
        "IgnorePublicAcls" => true,
        "RestrictPublicBuckets" => true
      )
    })
    template.has_parameter("Versioning", "Type" => "String", "Default" => "Suspended")
    template.has_resource("AWS::S3::Bucket",
      "DeletionPolicy" => "RetainExceptOnCreate",
      "UpdateReplacePolicy" => "Retain")
    assert_nil template.to_json["Outputs"], "the scaffold's stack is minimal: no outputs"
  end

  def test_the_scaffold_is_deterministic_across_two_runs
    cli("new", NAME)
    FileUtils.mv(project_dir, File.join(@dir, "first"))
    cli("new", NAME)

    files = [ ".gitattributes", ".gitignore", "Gemfile", "README.md", "cdk.rb", "my_app/my_app_stack.rb" ]
    files.each do |relative|
      assert_equal File.binread(File.join(@dir, "first", relative)), File.binread(File.join(project_dir, relative)),
        "#{relative} is the same bytes both times"
    end
  end

  # --- what it refuses

  def test_new_refuses_a_directory_that_holds_visible_files
    cli("new", NAME)
    untouched = File.read(File.join(project_dir, "cdk.rb"))

    plain = cli("new", NAME)
    forced = cli("new", NAME, "--force")

    assert_equal 1, plain.code
    assert_includes plain.err.string, "cannot write into a non-empty directory"
    assert_includes plain.err.string, "Found 4 visible file(s)"
    assert_includes plain.err.string, "  - cdk.rb"
    assert_equal 1, forced.code, "--force never overwrites files"
    assert_includes forced.err.string, "cannot write into a non-empty directory"
    assert_equal untouched, File.read(File.join(project_dir, "cdk.rb")), "nothing was overwritten"
  end

  def test_new_refuses_an_existing_directory_unless_it_is_empty_and_force_says_so
    made = File.join(@dir, "made-first")
    FileUtils.mkdir_p(made)

    plain = cli("new", "made-first")

    assert_equal 1, plain.code
    assert_includes plain.err.string, made
    assert_includes plain.err.string, "It is empty"
    assert_includes plain.err.string, "--force"

    only_dots = File.join(@dir, "has-git")
    FileUtils.mkdir_p(File.join(only_dots, ".git"))
    refused = cli("new", "has-git")

    assert_equal 1, refused.code
    assert_includes refused.err.string, "It holds only dot-files", "as the CDK counts, dot-files are not files"

    assert_equal 0, cli("new", "made-first", "--force").code
    assert File.file?(File.join(made, "cdk.rb"))
    assert_equal 0, cli("new", "has-git", "--force").code
    assert File.file?(File.join(only_dots, "cdk.rb"))
    assert File.directory?(File.join(only_dots, ".git")), "what was there stays"
  end

  def test_new_refuses_a_path_that_is_a_file
    FileUtils.touch(File.join(@dir, "occupied"))

    result = cli("new", "occupied")

    assert_equal 1, result.code
    assert_includes result.err.string, "exists and is not a directory"
  end

  def test_new_refuses_a_name_it_cannot_turn_into_a_project
    {
      "2fast" => "is not a project name",
      "has space" => "is not a project name",
      "" => "Name the project directory",
      "stack" => "would define the module Stack",
      "time" => "would define the module Time"
    }.each do |name, expected|
      result = cli("new", name)

      assert_equal 1, result.code, name.inspect
      assert_includes result.err.string, expected, name.inspect
    end
    refute File.exist?(File.join(@dir, "2fast")), "a refused name wrote nothing"
  end

  def test_new_writes_nothing_without_the_project
    result = cli("new")

    assert_equal 1, result.code
    assert_includes result.err.string, "Name the project directory"
    assert_includes result.err.string, "Run `ruby-cdk new NAME` again"
  end

  # The tests that load the generated app file define MyApp at the top level,
  # and the generator refuses a name whose module is taken. Minitest shuffles,
  # so whatever this class loaded before another test must be taken back out:
  # the suite is order-independent by construction.
  def teardown
    Object.send(:remove_const, "MyApp") if Object.const_defined?("MyApp")
    super
  end

  # --- the help of every command (audit S5)

  def test_h_and_help_print_a_command_s_help_and_succeed
    (RubyCdk::CLI.all_commands.keys + [ "list" ]).each do |command|
      [ "-h", "--help" ].each do |flag|
        result = cli(command, flag)

        assert_equal 0, result.code, "ruby-cdk #{command} #{flag}"
        assert result.out.string.start_with?("Usage:"), "ruby-cdk #{command} #{flag} prints usage"
      end
    end
  end

  def test_a_help_flag_between_other_words_still_answers_the_help
    result = cli("deploy", "--all", "--help")

    assert_equal 0, result.code
    assert result.out.string.start_with?("Usage:")
  end

  def test_the_help_of_synth_is_pinned
    expected = <<~OUTPUT
      Usage:
        ruby-cdk synth [STACK...]

      Options:
            [--no-validate]                                # Skip the schema rules (V1 to V23). The tree's own rules (V2, V13) still run
        -a, [--app=APP]                                    # The app file, which creates exactly one RubyCdk::App. A relative path is read from the working directory
                                                           # Default: cdk.rb
        -o, [--out=OUT]                                    # Directory the templates and manifest.json are written to. An App the app file creates with out_dir: keeps its own
                                                           # Default: cdk.out
            [--profile=PROFILE]                            # The AWS profile that selects the credentials
            [--region=REGION]                              # The AWS region the clients are built for. A stack with an env deploys only into that region
            [--account=ACCOUNT]                            # The 12-digit account the credentials must be for. Required with --yes for a stack without env
        -y, [--yes], [--no-yes], [--skip-yes]              # Deploy or destroy without asking for approval
        -f, [--force]                                      # Deploy even when the template and the parameters are unchanged; with destroy, do not ask for confirmation; with new, write into the directory named only when it is empty
        -q, [--quiet], [--no-quiet], [--skip-quiet]        # Print no progress, and for synth no template
        -v, [--verbose], [--no-verbose], [--skip-verbose]  # Say what the command decides, and print the backtrace of an error
        -j, [--json], [--no-json], [--skip-json]           # Print the result as JSON on standard output; what is for a person goes to standard error
            [--color], [--no-color], [--skip-color]        # Use colour even when standard output is not a terminal. --no-color never uses it

      Synthesize the app into --out, and print the template of the stack when there is one
    OUTPUT

    assert_equal expected, cli("synth", "--help").out.string
    assert_equal expected, cli("synth", "-h").out.string
    assert_equal 0, cli("synth", "--help").code
  end

  # --- helpers

  private

  def project_dir
    File.join(@dir, NAME) # the directory is the name as typed
  end
end
