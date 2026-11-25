# frozen_string_literal: true

require "test_helper"
require "support/cli_helpers"
require "ruby_cdk/deploy/fakes"

module CliTests
  # `ruby-cdk diff` (architecture section 10): the stacks it reads, the port it
  # reads them through, where the text goes, what --json answers, and the exit
  # codes. The CDK's own diff scenarios run beside these, in test/cdk/diff/.
  class DiffTest < CliHelpers::TestCase
    APP = <<~RUBY
      require "ruby-cdk"
      RubyCdk::App.new do |app|
        RubyCdk::Stack.new(app, "blog") do
          resource("Queue", "AWS::SQS::Queue")
        end
        RubyCdk::Stack.new(app, "site") do
          resource("Bucket", "AWS::S3::Bucket", properties: { "BucketName" => "the-bucket" })
        end
      end
    RUBY

    DEPLOYED = {
      "AWSTemplateFormatVersion" => "2010-09-09",
      "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } }
    }

    def setup
      super
      write_app(APP)
      @client = RubyCdk::Deploy::Fakes::CfnClient.new
      @aws = CliHelpers::FakeAws.new(cfn: @client)
    end

    def test_the_text_goes_to_standard_error_and_nothing_to_standard_out
      result = cli("diff", "blog", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "Stack blog"
      assert_includes result.err.string, "[+] AWS::SQS::Queue Queue"
      assert_equal "", result.out.string, "the text is for a person, and --json is how a machine reads the diff"
    end

    def test_json_answers_one_object_per_stack_on_standard_out_and_nothing_else_there
      result = cli("diff", "--all", "--json", aws: @aws)

      assert_equal 0, result.code
      records = result.records
      assert_equal %w[blog site], records.map { |record| record["name"] }
      blog = records.first
      assert_equal true, blog["has_changes"]
      assert_equal "Add", blog["resources"].first["action"]
      assert_equal [], blog["security"]["capabilities_added"], "no IAM resource in the stack, so no capability"
      assert_equal "", result.err.string, "under --json nothing is written for a person"
    end

    def test_json_security_changes_carry_the_statements
      role_app = <<~RUBY
        require "ruby-cdk"
        RubyCdk::App.new do |app|
          RubyCdk::Stack.new(app, "blog") do
            resource("Role", "AWS::IAM::Role", properties: {
              "AssumeRolePolicyDocument" => { "Statement" => { "Effect" => "Allow",
                "Principal" => { "Service" => "sns.amazonaws.com" }, "Action" => "sts:AssumeRole" } },
              "Policies" => [ { "PolicyName" => "p", "PolicyDocument" => {
                "Statement" => { "Effect" => "Allow", "Action" => "s3:*", "Resource" => "*" } } } ]
            } )
          end
        end
      RUBY
      write_app(role_app)
      result = cli("diff", "blog", "--json", aws: @aws)

      security = result.records.first["security"]
      assert_equal true, security["broadening"]
      assert_equal %w[CAPABILITY_IAM], security["capabilities_added"]
      actions = security["statements"]["additions"].flat_map { |statement| statement["actions"]["values"] }
      assert_equal %w[s3:* sts:AssumeRole], actions.sort
    end

    def test_no_changes_reads_as_the_cdk_reads_it_and_exits_0
      @client.stack("blog", status: "CREATE_COMPLETE", template: DEPLOYED)
      result = cli("diff", "blog", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "Stack blog"
      assert_includes result.err.string, "There were no differences"
      assert_includes result.err.string, "Number of stacks with differences: 0"
    end

    def test_an_empty_diff_with_json_answers_has_changes_false
      @client.stack("blog", status: "CREATE_COMPLETE", template: DEPLOYED)
      result = cli("diff", "blog", "--json", aws: @aws)

      assert_equal [ false ], result.records.map { |record| record["has_changes"] }
    end

    def test_fail_exits_1_when_a_stack_has_differences
      result = cli("diff", "blog", "--fail", aws: @aws)

      assert_equal 1, result.code
    end

    def test_fail_exits_0_when_nothing_differs
      @client.stack("blog", status: "CREATE_COMPLETE", template: DEPLOYED)
      result = cli("diff", "blog", "--fail", aws: @aws)

      assert_equal 0, result.code
    end

    def test_fail_across_stacks_exits_1_when_any_of_them_differs
      @client.stack("blog", status: "CREATE_COMPLETE", template: DEPLOYED)
      result = cli("diff", "--all", "--fail", aws: @aws)

      assert_equal 1, result.code
      assert_includes result.err.string, "Number of stacks with differences: 1"
    end

    def test_a_replacement_is_read_from_the_schema_model
      @client.stack("site", status: "CREATE_COMPLETE", template: {
        "AWSTemplateFormatVersion" => "2010-09-09",
        "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "old-name" } } }
      })
      result = cli("diff", "site", aws: @aws)

      assert_includes result.err.string, "[~] AWS::S3::Bucket Bucket replace"
      assert_includes result.err.string, "(requires replacement)"
    end

    def test_the_deployed_template_is_read_through_the_port_and_nothing_else_is_asked
      @client.stack("blog", status: "CREATE_COMPLETE", template: DEPLOYED)
      cli("diff", "blog", aws: @aws)

      assert_equal [ :get_template ], @client.operations
    end

    def test_a_yaml_deployed_template_is_read_too
      @client.stack("blog", status: "CREATE_COMPLETE",
        template: "AWSTemplateFormatVersion: '2010-09-09'\nResources:\n  Queue:\n    Type: AWS::SQS::Queue\n")
      result = cli("diff", "blog", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "There were no differences"
    end

    def test_a_deployed_template_that_is_neither_json_nor_yaml_is_reported
      @client.on(:get_template, "{ neither")
      result = cli("diff", "blog", aws: @aws)

      assert_equal 1, result.code
      assert_includes result.err.string, "The deployed template of stack blog cannot be read"
    end

    def test_the_stacks_follow_the_deploy_selection_rules
      # One stack, none named.
      FileUtils.mkdir_p(File.join(@dir, "solo"))
      File.write(File.join(@dir, "solo", "cdk.rb"), <<~RUBY)
        require "ruby-cdk"
        RubyCdk::App.new do |app|
          RubyCdk::Stack.new(app, "only") do
            resource("Queue", "AWS::SQS::Queue")
          end
        end
      RUBY
      result = cli("diff", "--app", "solo/cdk.rb", aws: @aws)
      assert_equal 0, result.code

      # Several stacks, none named: the CDK's usage error, in its words.
      result = cli("diff", aws: @aws)
      assert_equal 1, result.code
      assert_includes result.err.string, "Since this app includes more than a single stack, specify which stacks to use"

      # --all and names together are refused, as deploy refuses them.
      result = cli("diff", "--all", "blog", aws: @aws)
      assert_equal 1, result.code
      assert_includes result.err.string, "You must either specify a list of Stacks or the `--all` argument"
    end

    def test_a_named_stack_brings_its_dependencies_and_says_so
      deps_app = <<~RUBY
        require "ruby-cdk"
        RubyCdk::App.new do |app|
          RubyCdk::Stack.new(app, "base") do
            resource("Queue", "AWS::SQS::Queue")
          end
          top = RubyCdk::Stack.new(app, "top") do
            resource("Queue", "AWS::SQS::Queue")
          end
          top.add_dependency(app.stacks.find { |stack| stack.stack_name == "base" })
        end
      RUBY
      write_app(deps_app)
      result = cli("diff", "top", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "Including dependency stacks: base"
      assert_includes result.err.string, "Stack base"
      assert_includes result.err.string, "Stack top"
    end

    def test_exclusively_leaves_the_dependencies_alone
      deps_app = <<~RUBY
        require "ruby-cdk"
        RubyCdk::App.new do |app|
          RubyCdk::Stack.new(app, "base") do
            resource("Queue", "AWS::SQS::Queue")
          end
          top = RubyCdk::Stack.new(app, "top") do
            resource("Queue", "AWS::SQS::Queue")
          end
          top.add_dependency(app.stacks.find { |stack| stack.stack_name == "base" })
        end
      RUBY
      write_app(deps_app)
      result = cli("diff", "top", "--exclusively", aws: @aws)

      assert_equal 0, result.code
      refute_includes result.err.string, "Stack base"
    end

    def test_quiet_keeps_the_stack_out_when_nothing_differs
      @client.stack("blog", status: "CREATE_COMPLETE", template: DEPLOYED)
      result = cli("diff", "blog", "--quiet", aws: @aws)

      assert_equal 0, result.code
      refute_includes result.err.string, "Stack blog"
      assert_includes result.err.string, "Number of stacks with differences: 0"
    end

    def test_security_only_shows_the_security_view_and_nothing_else
      role_app = role_app_file
      write_app(role_app)
      result = cli("diff", "blog", "--security-only", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "IAM Statement Changes"
      refute_includes result.err.string, "Resources"
    end

    def test_security_only_with_no_security_changes_says_so
      result = cli("diff", "blog", "--security-only", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "There were no security-related changes"
      assert_includes result.err.string, "Number of stacks with differences: 0"
    end

    def test_a_stack_in_another_region_is_read_through_that_region
      env_app = <<~RUBY
        require "ruby-cdk"
        RubyCdk::App.new do |app|
          RubyCdk::Stack.new(app, "blog", env: RubyCdk::Env.new(account: "#{CliHelpers::ACCOUNT}", region: "eu-central-1")) do
            resource("Queue", "AWS::SQS::Queue")
          end
        end
      RUBY
      write_app(env_app)
      cli("diff", "blog", aws: @aws)

      assert_equal [ [ nil, "eu-central-1" ] ], @aws.client_calls
    end

    def test_the_engine_is_never_brought_in_to_diff
      # The diff reads one template through the port; it creates no change set
      # and executes nothing, so the fake records get_template and only it.
      @client.stack("blog", status: "CREATE_COMPLETE", template: DEPLOYED)
      cli("diff", "blog", aws: @aws)

      refute_includes @client.operations, :create_change_set
      refute_includes @client.operations, :execute_change_set
    end

    private

    def role_app_file
      <<~RUBY
        require "ruby-cdk"
        RubyCdk::App.new do |app|
          RubyCdk::Stack.new(app, "blog") do
            resource("Role", "AWS::IAM::Role", properties: {
              "AssumeRolePolicyDocument" => { "Statement" => { "Effect" => "Allow",
                "Principal" => { "Service" => "sns.amazonaws.com" }, "Action" => "sts:AssumeRole" } },
              "Policies" => [ { "PolicyName" => "p", "PolicyDocument" => {
                "Statement" => { "Effect" => "Allow", "Action" => "s3:*", "Resource" => "*" } } } ]
            } )
          end
        end
      RUBY
    end
  end
end
