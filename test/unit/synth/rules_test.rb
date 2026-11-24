# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# The two rules that live with the pipeline: V2 on logical IDs and V13 on the stack name.
#
# A parameter, an output, a mapping, a condition and a resource are refused
# where they are declared with a logical ID CloudFormation cannot take (the
# stack's and the resource's tests hold that), so what reaches V2 is what a
# normalizer wrote. The bad ids here are written by one.
class SynthRulesTest < CoreHelpers::TestCase
  def setup
    super
    @removed_rules = []
    @registered_normalizers = []
  end

  def teardown
    @removed_rules.each { |validator| RubyCdk::Synth.register_validator(validator) }
    @registered_normalizers.each { |normalizer| RubyCdk::Synth.unregister_normalizer(normalizer) }
    super
  end

  # --- V2

  def test_a_logical_id_holds_letters_and_digits_only_in_every_section
    stack = build_stack do
      parameter("GoodParam", type: "String")
      mapping("GoodMap", "a" => { "b" => "c" })
      condition("GoodCondition", Fn.equals("a", "a"))
      resource("Good1", "AWS::DynamoDB::Table")
      output("Good2", value: 1)
    end
    writes_bad_ids(
      "Parameters" => { "bad_param" => { "Type" => "String" } },
      "Mappings" => { "Bad-Map" => { "a" => { "b" => "c" } } },
      "Conditions" => { "Bad_Condition" => { "Fn::Equals" => [ "a", "a" ] } },
      "Resources" => { "my_table" => { "Type" => "AWS::DynamoDB::Table" } },
      "Outputs" => { "bad_output" => { "Value" => 1 } }
    )

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal %w[ V2 V2 V2 V2 V2 ], error.issues.map(&:rule)
    assert_equal [
      "Parameters.bad_param", "Mappings.Bad-Map", "Conditions.Bad_Condition", "Resources.my_table", "Outputs.bad_output"
    ], error.issues.map(&:path)
    assert_equal "the logical ID \"my_table\" must hold letters and digits only", error.issues[3].message
    assert_equal "CloudFormation takes no \"_\", \"-\" or \".\" in a logical ID: write MyTable", error.issues[3].hint
    assert_equal "V2 Resources.my_table: the logical ID \"my_table\" must hold letters and digits only", error.message.lines[3].chomp
  end

  def test_an_element_with_a_logical_id_cloudformation_cannot_take_is_refused_where_it_is_declared
    stack = build_stack { parameter("Stage", type: "String") }
    fault = 'the logical ID "table_name" must hold letters and digits only. ' \
      'CloudFormation takes no "_", "-" or "." in a logical ID: write TableName'

    [
      [ "the parameter \"table_name\"", -> { stack.parameter("table_name", type: "String") } ],
      [ "the output \"table_name\"", -> { stack.output("table_name", value: 1) } ],
      [ "the mapping \"table_name\"", -> { stack.mapping("table_name", "a" => { "b" => "c" }) } ],
      [ "the condition \"table_name\"", -> { stack.condition("table_name", Fn.equals("a", "a")) } ]
    ].each do |kind, declare|
      error = assert_raises(RubyCdk::UsageError, kind) { declare.call }

      assert_equal "App/blog: #{kind}: #{fault}", error.message, kind
    end
    assert_equal %w[ Stage ], stack.parameters.keys
    assert_empty stack.outputs
    assert_empty stack.mappings
    assert_empty stack.conditions
  end

  def test_an_id_that_is_not_even_a_construct_id_is_refused_in_the_construct_s_words
    stack = build_stack

    error = assert_raises(RubyCdk::UsageError) { stack.output("table_name!", value: 1) }

    assert_equal 'The id "table_name!" under App/blog is not valid: an id holds letters, digits, "_" and "-", and at least one of them',
      error.message
  end

  def test_a_logical_id_longer_than_255_characters_is_refused_where_it_is_declared
    # One id alone is refused as a construct id; the logical ID of a resource is
    # the ids above it joined, and that is what can outgrow 255.
    stack = build_stack
    long = "T" * 256

    error = assert_raises(RubyCdk::UsageError) { stack.output(long, value: 1) }

    assert_equal "The id \"#{long[0, 32]}...\" under App/blog is longer than 255 characters", error.message

    error = assert_raises(RubyCdk::UsageError) do
      stack_class { RubyCdk::Construct.new(self, "T" * 128).resource("T" * 128, "AWS::SNS::Topic") }.new(build_app(env: TEST_ENV), "blog")
    end

    assert_equal "resource \"#{'T' * 128}\" in App/blog/#{'T' * 128}: the logical ID \"#{'T' * 32}...\" is longer than 255 characters",
      error.message
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
    stack = build_stack { resource("Table", "AWS::DynamoDB::Table") }
    writes_bad_ids("Resources" => { "my_table" => { "Type" => "AWS::DynamoDB::Table" } })

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal [ "V2" ], error.issues.map(&:rule)

    without_rule(RubyCdk::Synth::Rules::LogicalIds)

    assert_equal %w[ my_table Table ], stack.to_template["Resources"].keys
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

  # Registers a normalizer that writes additions, a Hash of section to section,
  # into the template; teardown takes it out. This is how a logical ID that no
  # declaration can produce reaches V2.
  def writes_bad_ids(additions)
    normalizer = lambda { |context|
      additions.each do |section, entries|
        written = context.template[section] || {}
        context.template[section] = entries.merge(written)
      end
      context.template
    }
    RubyCdk::Synth.register_normalizer(normalizer)
    @registered_normalizers << normalizer
  end
end
