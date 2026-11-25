# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/diff"

module DiffTests
  # The text a person reads (architecture section 10): the CDK's sections and
  # markers, held as golden lines. Where the CDK draws a box table in colour,
  # this is plain text (recorded in architecture section 21).
  class RenderTest < Minitest::Test
    def test_the_whole_diff_of_a_changing_stack
      old = {
        "Description" => "before",
        "Parameters" => { "EnvType" => { "Type" => "String", "Default" => "dev" } },
        "Resources" => {
          "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "Name1" } },
          "Gone" => { "Type" => "AWS::SQS::Queue" }
        }
      }
      new = {
        "Description" => "after",
        "Parameters" => { "EnvType" => { "Type" => "String", "Default" => "prod" } },
        "Resources" => {
          "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "Name2" } },
          "Fresh" => { "Type" => "AWS::SQS::Queue" }
        }
      }
      diff = RubyCdk::Diff.of(old, new, stack_name: "blog")

      assert_equal <<~TEXT.chomp, RubyCdk::Diff.render(diff)
        Stack blog
        Template
        [~] Description: before to after

        Parameters
        [~] Parameter EnvType: {"Type":"String","Default":"dev"} to {"Type":"String","Default":"prod"}

        Resources
        [-] AWS::SQS::Queue Gone destroy
        [+] AWS::SQS::Queue Fresh
        [~] AWS::S3::Bucket Bucket replace
         └─ [~] BucketName (requires replacement)
            ├─ [-] Name1
            └─ [+] Name2
      TEXT
    end

    def test_no_changes_reads_as_the_cdk_reads_it
      template = { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } }
      diff = RubyCdk::Diff.of(template, template, stack_name: "blog")

      assert_equal "Stack blog\nThere were no differences", RubyCdk::Diff.render(diff)
    end

    def test_quiet_leaves_the_stack_out_when_nothing_changes_and_keeps_it_when_there_is
      template = { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } }
      quiet_empty = RubyCdk::Diff.render(RubyCdk::Diff.of(template, template, stack_name: "blog"), quiet: true)
      changed = RubyCdk::Diff.of(template, { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue", "Properties" => { "QueueName" => "n" } } } },
        stack_name: "blog")
      quiet_full = RubyCdk::Diff.render(changed, quiet: true)

      assert_equal "", quiet_empty
      assert_includes quiet_full, "Stack blog"
    end

    def test_the_security_tables_come_before_the_resources_and_carry_the_warning
      old = { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } }
      role = { "Type" => "AWS::IAM::Role", "Properties" => {
        "Policies" => [ { "PolicyName" => "p", "PolicyDocument" => { "Statement" => { "Effect" => "Allow", "Action" => "s3:*", "Resource" => "*" } } } ]
      } }
      new = { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" }, "Role" => role } }
      text = RubyCdk::Diff.render(RubyCdk::Diff.of(old, new, stack_name: "blog"))
      lines = text.split("\n")

      assert_includes lines, "This deployment will make potentially sensitive changes according to your current security approval level."
      tables_at = lines.index("IAM Statement Changes")
      resources_at = lines.index("Resources")
      refute_nil tables_at
      assert_operator tables_at, :<, resources_at
      row = lines.find { |line| line.start_with?("+ ") }
      assert_includes row, "s3:*"
    end

    def test_the_statement_table_keeps_its_columns_in_line
      security = RubyCdk::Diff::Security.build(RubyCdk::Diff.of(
        { "Resources" => {} },
        { "Resources" => role_with_statement("sns:Publish", { "Service" => "sns.amazonaws.com" }, with_condition: true) }
      ))
      rows = render_table(security)

      # Every column starts at the same place in the header as in the row:
      # the table is aligned, whatever the cells hold. The statement sits in a
      # role's Policies, so its principal is defaulted to the role and its
      # resource reads as written.
      assert_equal rows.first.index("Resource"), rows[1].index("*")
      assert_equal rows.first.index("Principal"), rows[1].index("Service:sns.amazonaws.com")
      # The condition column renders its JSON, quotes included.
      assert_equal rows.first.index("Condition"), rows[1].index('"ArnLike"')
    end

    def test_the_security_only_view_shows_the_security_tables_and_nothing_else
      old = { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } }
      resources = { "Queue" => { "Type" => "AWS::SQS::Queue" } }
      resources.merge!(role_with_statement("s3:*"))
      new = { "Resources" => resources }
      diff = RubyCdk::Diff.of(old, new, stack_name: "blog")
      lines = RubyCdk::Diff.render(diff, security_only: true).split("\n")

      assert_equal "Stack blog", lines.first
      assert_includes lines, "IAM Statement Changes"
      refute_includes lines, "Resources"
      refute_includes lines, "AWS::SQS::Queue"
    end

    def test_the_security_only_view_without_security_changes_says_so
      template = { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } }
      diff = RubyCdk::Diff.of(template, template, stack_name: "blog")

      # Without --quiet the stack is named even when it has nothing to say,
      # as the CDK names it (its io host prints the stack header before the
      # security view whatever it holds).
      assert_equal "Stack blog\nThere were no security-related changes", RubyCdk::Diff.render(diff, security_only: true)
    end

    def test_the_capabilities_line_reads_with_its_reason
      old = { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } }
      named = role_with_statement("s3:*")
      named["Role"]["Properties"]["RoleName"] = "named"
      new = { "Resources" => named }
      text = RubyCdk::Diff.render(RubyCdk::Diff.of(old, new, stack_name: "blog"), security_only: true)

      assert_includes text, "New capabilities needed: CAPABILITY_IAM, CAPABILITY_NAMED_IAM, because the new template creates IAM resources, some with explicit names."
    end

    def test_a_removed_value_reads_as_one_line_and_an_added_one_as_another
      old = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "keep" } } } }
      new = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" } } }
      text = RubyCdk::Diff.render(RubyCdk::Diff.of(old, new, stack_name: "x"))

      # The property is gone, so its own line is a removal; the resource still
      # replaces, because the removed path is create-only.
      assert_includes text, " └─ [-] BucketName (requires replacement)"
      assert_includes text, "    └─ [-] keep"
    end

    private

    def role_with_statement(action, principal = "*", with_condition: false)
      statement = { "Effect" => "Allow", "Action" => action, "Resource" => "*", "Principal" => principal }
      statement["Condition"] = { "ArnLike" => { "AWS:SourceArn" => "arn:aws:sns:eu-west-1:111122223333:t" } } if with_condition
      document = { "Statement" => statement }
      {
        "Role" => { "Type" => "AWS::IAM::Role", "Properties" => {
          "Policies" => [ { "PolicyName" => "p", "PolicyDocument" => document } ]
        } }
      }
    end

    # The rows of the statement table, as the renderer lays them out, so the
    # test can see the columns stay in line.
    def render_table(security)
      statement = security.statement_additions.first
      row = RubyCdk::Diff::Render.row("+", statement)
      RubyCdk::Diff::Render.table([ "", "Resource", "Effect", "Action", "Principal", "Condition" ], [ row ])
    end
  end
end
