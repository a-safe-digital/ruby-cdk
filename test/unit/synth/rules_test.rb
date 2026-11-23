# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# The two rules that live with the pipeline: V2 on logical IDs and V13 on the stack name.
class SynthRulesTest < CoreHelpers::TestCase
  def setup
    super
    @removed_rules = []
  end

  def teardown
    @removed_rules.each { |validator| RubyCdk::Synth.register_validator(validator) }
    super
  end

  # --- V2

  def test_a_logical_id_holds_letters_and_digits_only_in_every_section
    stack = build_stack do
      parameter("bad_param", type: "String")
      mapping("Bad-Map", "a" => { "b" => "c" })
      condition("Bad_Condition", Fn.equals("a", "a"))
      resource("my_table", "AWS::DynamoDB::Table")
      output("bad_output", value: 1)
      resource("Good1", "AWS::DynamoDB::Table")
      output("Good2", value: 1)
    end

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal %w[ V2 V2 V2 V2 V2 ], error.issues.map(&:rule)
    assert_equal [
      "Parameters.bad_param", "Mappings.Bad-Map", "Conditions.Bad_Condition", "Resources.my_table", "Outputs.bad_output"
    ], error.issues.map(&:path)
    assert_equal "the logical ID \"my_table\" must hold letters and digits only", error.issues[3].message
    assert_equal "CloudFormation takes no \"_\", \"-\" or \".\" in a logical ID: write MyTable", error.issues[3].hint
    assert_equal "V2 Resources.my_table: the logical ID \"my_table\" must hold letters and digits only", error.message.lines[3].chomp
  end

  def test_a_logical_id_names_one_thing_in_the_whole_stack
    stack = build_stack do
      parameter("Stage", type: "String")
      resource("Stage", "AWS::DynamoDB::Table")
      mapping("Other", "a" => { "b" => "c" })
      output("Other", value: 1)
      condition("Third", Fn.equals("a", "a"))
      resource("Third", "AWS::SQS::Queue")
    end

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal [ "Resources.Stage", "Resources.Third", "Outputs.Other" ], error.issues.map(&:path)
    assert_equal "the logical ID \"Stage\" is declared more than once in the stack: in Parameters.Stage and here",
      error.issues.first.message
  end

  def test_two_resources_can_end_up_with_one_logical_id
    stack = build_stack do
      RubyCdk::Construct.new(self, "Api").resource("Role", "AWS::IAM::Role")
      resource("ApiRole", "AWS::IAM::Role")
      resource("Role", "AWS::IAM::Role")
    end

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal [ "Resources.ApiRole" ], error.issues.map(&:path)
    assert_equal "the logical ID \"ApiRole\" is that of 2 resources: App/blog/Api/Role, App/blog/ApiRole", error.issues.first.message
  end

  def test_logical_ids_that_are_fine_raise_nothing
    stack = build_stack do
      parameter("Stage", type: "String")
      resource("Table2", "AWS::DynamoDB::Table")
      output("TableName", value: 1)
    end

    assert_equal [ "Table2" ], stack.to_template["Resources"].keys
  end

  def test_v2_fails_only_while_the_rule_is_registered
    stack = build_stack { resource("my_table", "AWS::DynamoDB::Table") }
    without_rule(RubyCdk::Synth::Rules::LogicalIds)

    assert_equal [ "my_table" ], stack.to_template["Resources"].keys
  end

  # --- V13

  def test_the_stack_name_is_checked_after_the_prefix
    stack = build_stack("1blog")

    assert_equal "1blog", stack.stack_name
    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal [ "V13" ], error.issues.map(&:rule)
    assert_equal "Stack", error.issues.first.path
    assert_equal "V13 Stack: the stack name \"1blog\" is not valid: it must start with a letter, go on with letters, digits and hyphens, " \
      "and be at most 128 characters long", error.message
    assert_equal "a stack's name is the prefix of App.new(stack_name_prefix:) followed by its id", error.issues.first.hint
  end

  def test_every_rule_of_the_stack_name
    [ "1blog", "my_blog", "-blog", "a" * 129 ].each do |name|
      stack = build_stack(name)

      error = assert_raises(RubyCdk::ValidationError, name) { stack.to_template }

      assert_equal "V13", error.issues.first.rule, name
    end

    %w[ blog my-blog-stack B2B a blog- ].each do |name|
      assert_equal name, build_stack(name).stack_name
      assert_kind_of Hash, build_stack(name).to_template
    end
    refute build_stack("a" * 128).to_template.key?("Resources")
  end

  def test_v13_fails_only_while_the_rule_is_registered
    stack = build_stack("1blog")
    without_rule(RubyCdk::Synth::Rules::StackName)

    refute stack.to_template.key?("Resources")
  end

  def test_a_prefix_that_breaks_the_name_is_reported_with_the_whole_name
    stack = build_stack("blog", app_options: { stack_name_prefix: "9acme-" })

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_match(/the stack name "9acme-blog" is not valid/, error.message)
  end

  private

  # Takes a rule out of the pipeline for one test; teardown puts it back.
  def without_rule(klass)
    RubyCdk::Synth.validators.select { |validator| validator.is_a?(klass) }.each do |validator|
      RubyCdk::Synth.unregister_validator(validator)
      @removed_rules << validator
    end
  end
end
