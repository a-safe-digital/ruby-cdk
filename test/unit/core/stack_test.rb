# frozen_string_literal: true

require "test_helper"
require "digest"
require "support/core_helpers"

# One template: how it is built, what it declares, and its name.
class CoreStackTest < CoreHelpers::TestCase
  def test_the_block_runs_at_once_in_the_context_of_the_stack
    seen = nil
    stack = RubyCdk::Stack.new(build_app, "blog") do
      seen = [ self, stack_name ]
      resource("Table", "AWS::DynamoDB::Table")
    end

    assert_equal [ stack, "blog" ], seen
    assert_equal %w[Table], stack.resources.map(&:logical_id)
  end

  def test_the_block_may_take_the_stack_as_its_argument
    stack = RubyCdk::Stack.new(build_app, "blog") { |s| s.resource("Table", "AWS::DynamoDB::Table") }

    assert_equal %w[Table], stack.resources.map(&:logical_id)
  end

  def test_a_subclass_builds_itself_when_no_block_is_given
    klass = Class.new(RubyCdk::Stack) do
      def build
        resource("Table", "AWS::DynamoDB::Table")
      end
    end

    assert_equal %w[Table], klass.new(build_app, "blog").resources.map(&:logical_id)
    assert_empty RubyCdk::Stack.new(build_app, "empty").resources
  end

  def test_the_block_wins_over_build
    klass = Class.new(RubyCdk::Stack) do
      def build
        resource("FromBuild", "AWS::SNS::Topic")
      end
    end
    stack = klass.new(build_app, "blog") { resource("FromBlock", "AWS::SQS::Queue") }

    assert_equal %w[FromBlock], stack.resources.map(&:logical_id)
  end

  def test_a_stack_is_created_in_an_app
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")

    assert_same app, stack.app
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Stack.new(stack, "nested") }

    assert_match(/A Stack is created in an App/, error.message)
    assert_raises(RubyCdk::UsageError) { RubyCdk::Stack.new(nil, "blog") }
    assert_raises(RubyCdk::UsageError) { RubyCdk::Stack.new(Object.new, "blog") }
  end

  def test_the_stack_name_is_the_prefix_of_the_app_followed_by_the_id
    assert_equal "blog", build_stack.stack_name
    assert_equal "acme-blog", build_stack(app_options: { stack_name_prefix: "acme-" }).stack_name
    assert_equal "blog", RubyCdk::Stack.new(build_app(stack_name_prefix: nil), "blog").stack_name
  end

  def test_env_is_the_stack_s_then_the_app_s_then_nil
    other = RubyCdk::Env.new(account: "999988887777", region: "us-east-1")

    assert_nil RubyCdk::Stack.new(build_app, "a").env
    assert_same TEST_ENV, RubyCdk::Stack.new(build_app(env: TEST_ENV), "b").env
    assert_same other, RubyCdk::Stack.new(build_app(env: TEST_ENV), "c", env: other).env

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Stack.new(build_app, "d", env: "eu-west-1") }

    assert_match(/env must be a RubyCdk::Env, got "eu-west-1"/, error.message)
  end

  def test_stateful_default_is_the_stack_s_then_the_app_s_then_retain_except_on_create
    assert_equal :retain_except_on_create, RubyCdk::Stack.new(build_app, "a").stateful_default
    assert_equal :delete, RubyCdk::Stack.new(build_app(stateful_default: :delete), "b").stateful_default
    assert_equal :delete, RubyCdk::Stack.new(build_app(stateful_default: :delete), "c").stateful_default
    assert_equal :delete, RubyCdk::Stack.new(build_app, "d", stateful_default: :delete).stateful_default
    assert_equal :retain_except_on_create, RubyCdk::Stack.new(build_app(stateful_default: :delete), "e", stateful_default: :retain_except_on_create).stateful_default

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Stack.new(build_app, "e", stateful_default: :snapshot) }

    assert_match(/stateful_default: :snapshot is not one of :retain_except_on_create, :delete/, error.message)
  end

  def test_termination_protection_is_off_unless_asked_for
    assert_equal false, build_stack.termination_protection
    assert_equal true, build_stack(stack_options: { termination_protection: true }).termination_protection
    assert_equal true, build_stack(stack_options: { termination_protection: "yes" }).termination_protection
  end

  def test_the_description_is_a_string
    assert_nil build_stack.description
    assert_equal "The blog", build_stack(stack_options: { description: "The blog" }).description
    assert_equal "the_blog", build_stack(stack_options: { description: :the_blog }).description

    error = assert_raises(RubyCdk::UsageError) { build_stack(stack_options: { description: 42 }) }

    assert_match(/description must be a String or a Symbol, got 42/, error.message)
  end

  def test_tags_are_kept_as_strings_and_cannot_be_changed
    stack = build_stack(stack_options: { tags: { Team: "Platform", "Cost" => "blog" } })

    assert_equal({ "Team" => "Platform", "Cost" => "blog" }, stack.tags)
    assert_predicate stack.tags, :frozen?
    assert_equal({}, build_stack.tags)

    error = assert_raises(RubyCdk::UsageError) { build_stack(stack_options: { tags: [ "Team" ] }) }
    assert_match(/tags takes a Hash/, error.message)
    assert_raises(RubyCdk::UsageError) { build_stack(stack_options: { tags: { nil => "x" } }) }
    assert_raises(RubyCdk::UsageError) { build_stack(stack_options: { tags: { "Team" => nil } }) }
  end

  # --- the sections

  def test_a_parameter_is_a_handle_that_fn_ref_takes
    stack = build_stack do
      @stage = parameter("Stage", type: "String", default: "prod", description: "Where", allowed_values: %w[ dev prod ], no_echo: true)
      @bare = parameter("Count", type: "Number")
      @list = parameter(:Zones, type: "CommaDelimitedList")
    end
    stage = stack.instance_variable_get(:@stage)

    assert_kind_of RubyCdk::Core::Parameter, stage
    assert_equal "Stage", stage.logical_id
    assert_equal "Stage", stage.name
    assert_equal "Stage", stage.to_s
    assert_equal({ "Ref" => "Stage" }, Fn.ref(stage))
    assert_equal "String", stage.type
    assert_equal "prod", stage.default
    assert_equal "Where", stage.description
    assert_equal %w[ dev prod ], stage.allowed_values
    assert_equal true, stage.no_echo
    assert_equal false, stack.instance_variable_get(:@bare).no_echo
    assert_equal "Zones", stack.parameters.keys.last
    assert_equal "Zones", stack.instance_variable_get(:@list).logical_id
    assert_equal %w[ Stage Count Zones ], stack.parameters.keys
    assert_predicate stack.parameters, :frozen?
  end

  def test_a_parameter_is_declared_once_and_with_a_type
    stack = build_stack { parameter("Stage", type: "String") }

    error = assert_raises(RubyCdk::UsageError) { stack.parameter("Stage", type: "String") }

    assert_equal "App/blog declares \"Stage\" twice", error.message
    assert_raises(RubyCdk::UsageError) { stack.parameter("Count", type: 42) }
    assert_raises(RubyCdk::UsageError) { stack.parameter("Count", type: "Number", allowed_values: "1") }
    assert_raises(RubyCdk::UsageError) { stack.parameter("bad param", type: "String") }
    assert_equal %w[ Stage ], stack.parameters.keys
  end

  def test_an_output_and_an_export
    stack = build_stack do
      @plain = output("TableName", value: "t", description: "The table")
      @exported = export("VpcId", value: "vpc")
      @conditional = output("OnlyInProd", value: 1, export: true, condition: "IsProd")
    end
    plain = stack.instance_variable_get(:@plain)
    exported = stack.instance_variable_get(:@exported)

    assert_kind_of RubyCdk::Core::Output, plain
    assert_equal "TableName", plain.logical_id
    assert_equal "The table", plain.description
    assert_equal false, plain.export
    assert_equal true, exported.export
    assert_equal "vpc", exported.value
    assert_equal "OnlyInProd", stack.instance_variable_get(:@conditional).logical_id
    assert_equal %w[ TableName VpcId OnlyInProd ], stack.outputs.keys
    assert_equal "blog-VpcId", stack.export_name("VpcId")
    # An output's id is its logical ID, and a logical ID holds letters and digits only.
    error = assert_raises(RubyCdk::UsageError) { stack.export_name(:vpc_id) }

    assert_match(/must hold letters and digits only/, error.message)
  end

  def test_an_output_needs_a_value_and_a_boolean_export
    stack = build_stack { output("A", value: 1) }

    assert_raises(RubyCdk::UsageError) { stack.output("B", value: nil) }
    assert_raises(RubyCdk::UsageError) { stack.output("C", value: 1, export: "name") }
    assert_raises(RubyCdk::UsageError) { stack.output("A", value: 1) }
    assert_raises(RubyCdk::UsageError) { stack.output("D", value: 1, condition: Object.new) }
    assert_raises(RubyCdk::UsageError) { stack.export("bad output", value: 1) }
    assert_equal %w[ A ], stack.outputs.keys
  end

  def test_a_mapping_a_condition_and_the_metadata
    stack = build_stack do
      @mapping = mapping("Regions", "eu" => { "west" => "eu-west-1" })
      @condition = condition("IsProd", Fn.equals("a", "a"))
      add_metadata("Notes", "none")
      add_metadata(:Owner, "platform")
    end
    condition = stack.instance_variable_get(:@condition)

    assert_equal "Regions", stack.instance_variable_get(:@mapping).to_s
    assert_equal({ "eu" => { "west" => "eu-west-1" } }, stack.instance_variable_get(:@mapping).hash)
    assert_equal "IsProd", condition.name
    assert_equal({ "Fn::Equals" => [ "a", "a" ] }, condition.fn)
    assert_equal({ "Fn::If" => [ "IsProd", "y", "n" ] }, Fn.if(condition, "y", "n"))
    assert_equal({ "Fn::FindInMap" => [ "Regions", "eu", "west" ] }, Fn.find_in_map(stack.instance_variable_get(:@mapping), "eu", "west"))
    assert_equal({ "Notes" => "none", "Owner" => "platform" }, stack.metadata)
    assert_equal %w[ Regions ], stack.mappings.keys
    assert_equal %w[ IsProd ], stack.conditions.keys

    assert_raises(RubyCdk::UsageError) { stack.mapping("Bad", "not a hash") }
    assert_raises(RubyCdk::UsageError) { stack.condition("Bad", "not a function") }
    assert_raises(RubyCdk::UsageError) { stack.mapping("Regions", {}) }
    assert_raises(RubyCdk::UsageError) { stack.add_metadata(42, "x") }
    assert_equal({ "Notes" => "none", "Owner" => "platform" }, stack.metadata)
  end

  # --- names

  def test_unique_name_is_the_stack_the_suffix_and_eight_hex_characters_of_a_sha_256
    stack = build_stack

    assert_equal "blog-images-#{Digest::SHA256.hexdigest("111122223333:eu-west-1:blog:images")[0, 8]}", stack.unique_name("images")
    assert_equal "blog-#{Digest::SHA256.hexdigest("111122223333:eu-west-1:blog:")[0, 8]}", stack.unique_name
    assert_equal stack.unique_name("images"), stack.unique_name(:images)
    assert_match(/\Ablog-images-[0-9a-f]{8}\z/, stack.unique_name("images"))
  end

  def test_unique_name_changes_with_the_account_the_region_the_stack_and_the_suffix
    names = [
      build_stack.unique_name("images"),
      build_stack("blog2").unique_name("images"),
      build_stack(app_options: { stack_name_prefix: "dev-" }).unique_name("images"),
      build_stack(app_options: { env: RubyCdk::Env.new(account: "111122223333", region: "us-east-1") }).unique_name("images"),
      build_stack(app_options: { env: RubyCdk::Env.new(account: "999988887777", region: "eu-west-1") }).unique_name("images")
    ]

    assert_equal names.length, names.uniq.length
  end

  def test_unique_name_holds_lower_case_letters_digits_and_hyphens
    stack = build_stack("My_Blog", app_options: { stack_name_prefix: "ACME." })

    name = stack.unique_name("User Images")
    assert_match(/\Aacme-my-blog-user-images-[0-9a-f]{8}\z/, name)
    assert_match(/\Ablog-[0-9a-f]{8}\z/, build_stack.unique_name("_"))
  end

  def test_unique_name_is_shortened_from_the_left
    stack = build_stack
    long = stack.unique_name("a-very-long-suffix-that-goes-on-and-on")

    assert_operator long.length, :>, 20
    assert_equal long[-20, 20], stack.unique_name("a-very-long-suffix-that-goes-on-and-on", max_length: 20)
    assert_match(/\A[0-9a-f]{8}\z/, stack.unique_name("images", max_length: 8))
    assert_equal long, stack.unique_name("a-very-long-suffix-that-goes-on-and-on", max_length: 128)
  end

  def test_the_default_length_never_gives_more_than_63_characters_so_the_name_is_always_a_valid_bucket_name
    assert_equal 63, RubyCdk::Stack::DEFAULT_UNIQUE_NAME_MAX_LENGTH

    long_stack = build_stack("a" * 120, app_options: { stack_name_prefix: "b" * 60 })
    names = [ long_stack.unique_name, long_stack.unique_name("images"), long_stack.unique_name("x" * 200), build_stack.unique_name ]

    names.each do |name|
      assert_operator name.length, :<=, 63, name
      assert_operator name.length, :>=, RubyCdk::Stack::MIN_UNIQUE_NAME_LENGTH, name
      assert_match(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, name)
    end
    assert_equal 63, names.first.length
    assert_equal 63, names[1].length
    # The name is the stack name, the suffix and the hash, shortened from the left:
    # what is kept of the stack name is its tail, here letters, then the suffix.
    assert_match(/\Aa+-images-[0-9a-f]{8}\z/, names[1])
  end

  def test_unique_name_needs_an_env_and_a_sensible_length
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Stack.new(build_app, "blog").unique_name("images") }

    assert_match(%r{\AApp/blog: unique_name needs a concrete env}, error.message)

    error = assert_raises(RubyCdk::UsageError) { build_stack.unique_name("images", max_length: 2) }
    assert_match(/at least 3, got 2/, error.message)
    assert_raises(RubyCdk::UsageError) { build_stack.unique_name("images", max_length: "64") }
  end

  # --- dependencies

  def test_a_stack_depends_on_other_stacks_in_the_order_it_was_told
    app = build_app
    first = RubyCdk::Stack.new(app, "first")
    second = RubyCdk::Stack.new(app, "second")
    last = stack_class { add_dependency(first) }.new(app, "last")

    assert_same last, last.add_dependency(second)
    assert_equal [ first, second ], last.dependencies
    assert_equal [ first, second ], last.add_dependency(first).dependencies
    assert_predicate last.dependencies, :frozen?
    assert_empty first.dependencies
  end

  def test_a_stack_cannot_depend_on_itself_or_on_something_that_is_not_a_stack
    stack = build_stack

    error = assert_raises(RubyCdk::UsageError) { stack.add_dependency(stack) }

    assert_match(/a stack cannot depend on itself/, error.message)
    assert_raises(RubyCdk::UsageError) { stack.add_dependency("other") }
    assert_raises(RubyCdk::UsageError) { stack.add_dependency(nil) }
    assert_empty stack.dependencies
  end
end
