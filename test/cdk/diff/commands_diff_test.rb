# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk/test/commands/diff.test.ts,
#            in aws/aws-cdk-cli
#   Commit:  eca1b73d682d7763955bec30ab5dd52bbc4327b6 (main, read on 2026-11-25)
#   Licence: Apache-2.0
#
# The origin holds 52 test declarations, each one case. The scenarios there
# run the CDK's diff command against a mock CloudFormation and read the exit
# code and the printed text; here they run `ruby-cdk diff` in process, over
# the app of four stacks the origin's beforeEach builds (A, B and C depending
# on A, D on its own), with the scripted fake of deploy/fakes.rb answering
# get_template: nothing deployed for A, B and C, and A's own template already
# deployed for D, which is what the origin's readCurrentTemplateWithNestedStacks
# mock answers.
#
# Changed, with nothing else in a scenario, an input or an outcome:
#   - toolkit.diff({ failOn: RequireApproval.ANYCHANGE }) is `ruby-cdk diff
#     --fail`: the CDK's --fail is its alias for --fail-on=any-change, and the
#     one fail behaviour this tool ports.
#   - "throws an error during diffs on stack with error metadata" expects the
#     synthesis to be rejected with "Synthesis finished with errors". Here the
#     pipeline raises at synthesis and the command line reports exit code 2
#     (architecture section 14): the assert names the exit code and the rule.
#   - "diff creates changeset for new stacks" proves the diff reaches the
#     account for a stack that does not exist. This tool's diff creates no
#     change set: it reads get_template, answers nil for the absent stack, and
#     diffs against nothing. The assert is on the outcome the CDK's case
#     protects -- a new stack diffs successfully and everything is an Add.
#   - "--fail-on=broadening works with --security-only" expects exit 1; this
#     tool ports --security-only without the --fail-on table, so the assert is
#     on what the case mostly protects: the security view alone is shown, with
#     the CDK's warning, and the command still exits 0 without --fail.
#
# Not ported, with the reason, case by case:
#
#   This tool's diff reads the deployed template through get_template and
#   prices replacements from the schema model; it creates no change set
#   (architecture section 10), so everything the origin's cases prove about
#   its change-set path has no counterpart:
#   - fixed template > fixed template with valid templates (--template PATH
#     is not an option here; backlog);
#   - import existing resources > import action in change set output; import
#     action in change set output when not using --import-exsting-resources;
#   - when invoked with method=template; passes the change set name to
#     createDiffChangeSet; passes global parameters to the change set with
#     stack-qualified overrides; when invoked with local template path;
#   - imports > imports render correctly for a nonexistant stack and diff
#     creates a changeset; imports render correctly for an existing stack and
#     diff creates a changeset (import is not in this version);
#   - stack exists checks > diff does not check for stack existence with
#     method=template; method=auto falls back to template diff when
#     stackExists call fails; method=change-set throws when stackExists call
#     fails; method=change-set creates changeset for new stacks (there is no
#     method table: the one path is template against get_template).
#
#   A later wave builds what these need:
#   - nested stacks > diff can diff nested stacks...; diff falls back to
#     non-changeset diff for nested stacks; when quiet mode is enabled, nested
#     stacks with no diffs...; when quiet mode is enabled, nested stacks with
#     diffs...; diff --security-only counts nested stacks with security
#     changes; diff --security-only --quiet suppresses stacks without security
#     changes (nested stacks are not in this version).
#
#   A difference by design, each recorded in architecture section 21:
#   - --strict > --strict does not obscure CDK::Metadata or
#     CheckBootstrapVersion; --no-strict obscures CDK::Metadata and
#     CheckBootstrapVersion (this tool synthesizes neither resource nor rule);
#   - stack display names > diff should display stack paths instead of logical
#     IDs; diff should fall back to logical ID if display name is not available
#     (logical IDs are the ids the user writes, D-004);
#   - environment annotation > the stack header shows the environment...; the
#     stack header is unannotated...; an environment-agnostic stack shows the
#     resolved environment...; diffing against a local template does not
#     resolve the environment (this header carries the stack's name alone);
#   - --fail-on > --fail-on=broadening still prints the full diff;
#     --fail-on=broadening works when comparing against a local template;
#     --fail-on=broadening detects broadening changes in nested stacks;
#     --fail-on=broadening works with --security-only when comparing against a
#     local template; the --fail-on test.each rows; --fail-on=destructive >
#     does not fail when the diff only updates resources in place; fails and
#     lists replaced, destroyed and orphaned resources; shows the construct
#     path...; takes the construct path...; detects destructive changes in
#     nested stacks; detects destructive changes with --security-only; does
#     not fail on replacements that the change set says will not happen; does
#     not fail on changes that are omitted as mangled non-ASCII characters;
#     does not fail when only CDK metadata is removed; detects destructive
#     changes when comparing against a local template (only --fail is ported,
#     the CDK's --fail-on=any-change; the broadening and destructive tables
#     are backlog);
#   - does not fail on changes that are omitted as mangled non-ASCII
#     characters (this tool mangles nothing).
#
# Parity: 52 cases in the origin; 11 ported; 41 not ported.

require "test_helper"
require "support/cli_helpers"

module CdkDiff
  # The app the origin's beforeEach builds: A with one resource, B and C
  # depending on it, D on its own. C carries the synthesis issue the origin's
  # error metadata stands for.
  class CommandsDiffTest < CliHelpers::TestCase
    APP = <<~RUBY
      require "ruby-cdk"
      RubyCdk::App.new do |app|
        RubyCdk::Stack.new(app, "A") do
          resource("Resource", "AWS::SQS::Queue")
        end
        b = RubyCdk::Stack.new(app, "B") do
          resource("Resource", "AWS::SQS::Queue")
        end
        b.add_dependency(app.stacks.find { |stack| stack.stack_name == "A" })
        c = RubyCdk::Stack.new(app, "C") do
          resource("Resource", "AWS::SQS::Queue")
        end
        c.add_dependency(app.stacks.find { |stack| stack.stack_name == "A" })
        RubyCdk::Stack.new(app, "D") do
          resource("Resource", "AWS::SQS::Queue")
        end
      end
    RUBY

    # The app of the "error metadata" case: stack C carries a property the
    # schema model does not know, which the pipeline rejects at synthesis --
    # this tool's counterpart of the origin's error metadata entry.
    BROKEN_APP = <<~RUBY
      require "ruby-cdk"
      RubyCdk::App.new do |app|
        RubyCdk::Stack.new(app, "C") do
          resource("Resource", "AWS::SQS::Queue", properties: { "NotARealProperty" => 1 })
        end
      end
    RUBY

    # The deployed stack the origin's mock answers for D: the template the app
    # synthesizes for it, so nothing differs. Everything else is deployed as
    # nothing.
    DEPLOYED_D = {
      "AWSTemplateFormatVersion" => "2010-09-09",
      "Resources" => { "Resource" => { "Type" => "AWS::SQS::Queue" } }
    }

    def setup
      super
      write_app(APP)
      @client = RubyCdk::Deploy::Fakes::CfnClient.new
      @client.stack("D", status: "CREATE_COMPLETE", template: DEPLOYED_D)
      @aws = CliHelpers::FakeAws.new(cfn: @client)
    end

    def test_diff_can_diff_multiple_stacks
      # `diff B` brings A, because B depends on it and a deploy would deploy it.
      result = cli("diff", "B", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "Stack A"
      assert_includes result.err.string, "Stack B"
      assert_includes result.err.string, "Number of stacks with differences: 2"
      assert_includes result.err.string, "Including dependency stacks: A"
    end

    def test_diff_number_of_stack_diffs_not_resource_diffs
      result = cli("diff", "A", "D", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "Stack A"
      assert_includes result.err.string, "Stack D"
      assert_includes result.err.string, "Number of stacks with differences: 1"
    end

    def test_exits_with_1_with_diffs_and_fail_set_to_true
      result = cli("diff", "A", "--fail", aws: @aws)

      assert_equal 1, result.code
      assert_includes result.err.string, "Number of stacks with differences: 1"
    end

    def test_throws_an_error_if_no_valid_stack_names_given
      result = cli("diff", "X", "Y", "Z", aws: @aws)

      assert_equal 1, result.code
      assert_includes result.err.string, "No stacks match the name(s) X, Y, Z"
    end

    def test_exits_with_1_with_diff_in_first_stack_but_not_in_second_stack_and_fail_set_to_true
      result = cli("diff", "A", "D", "--fail", aws: @aws)

      assert_equal 1, result.code
      assert_includes result.err.string, "Number of stacks with differences: 1"
    end

    def test_throws_an_error_during_diffs_on_stack_with_error_metadata
      write_app(BROKEN_APP)
      result = cli("diff", "C", aws: @aws)

      # The synthesis is what fails, before any diff: exit code 2, and the
      # report names the rule that caught the property.
      assert_equal 2, result.code
      assert_match(/NotARealProperty|V\d+/, result.err.string)
    end

    def test_when_quiet_mode_is_enabled_stacks_with_no_diffs_should_not_print_stack_name_and_no_differences
      result = cli("diff", "D", "--quiet", aws: @aws)

      assert_equal 0, result.code
      refute_includes result.err.string, "Stack D"
      refute_includes result.err.string, "There were no differences"
      assert_includes result.err.string, "Number of stacks with differences: 0"
    end

    def test_when_quiet_mode_is_enabled_stacks_with_diffs_should_print_stack_name
      result = cli("diff", "A", "--quiet", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "Stack A"
      assert_includes result.err.string, "Number of stacks with differences: 1"
    end

    def test_a_stack_that_is_not_deployed_diffs_against_nothing_and_everything_is_an_add
      # The CDK's "diff creates changeset for new stacks": the diff of a stack
      # that does not exist reaches the account and succeeds. Here it reads
      # get_template, answers nil, and everything is an Add.
      result = cli("diff", "A", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "[+] AWS::SQS::Queue Resource"
    end

    def test_security_only_shows_the_security_view_alone_with_the_cdk_warning
      role_app = <<~RUBY
        require "ruby-cdk"
        RubyCdk::App.new do |app|
          RubyCdk::Stack.new(app, "A") do
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
      result = cli("diff", "A", "--security-only", aws: @aws)

      assert_equal 0, result.code
      assert_includes result.err.string, "IAM Statement Changes"
      assert_includes result.err.string, "This deployment will make potentially sensitive changes"
      refute_includes result.err.string, "Resources"
    end

    def test_does_not_fail_by_default
      result = cli("diff", "A", aws: @aws)

      assert_equal 0, result.code
    end
  end
end
