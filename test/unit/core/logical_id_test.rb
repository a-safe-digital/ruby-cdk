# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# A logical ID is the id the user writes, with the ids of the constructs around a resource joined in front.
class CoreLogicalIdTest < CoreHelpers::TestCase
  def test_a_resource_directly_in_a_stack_keeps_its_id
    stack = build_stack { @table = resource("Table", "AWS::DynamoDB::Table") }
    table = stack.instance_variable_get(:@table)

    assert_kind_of RubyCdk::Cfn::Resource, table
    assert_equal "Table", table.logical_id
  end

  def test_a_resource_inside_a_construct_takes_the_ids_above_it_in_front
    stack = build_stack do
      api = RubyCdk::Construct.new(self, "Api")
      @role = api.resource("Role", "AWS::IAM::Role")
      @fn = api.resource("Fn", "AWS::Lambda::Function")
      version = RubyCdk::Construct.new(api, "V1")
      @nested = RubyCdk::Construct.new(version, "Deep").resource("Role", "AWS::IAM::Role")
    end

    assert_equal "ApiRole", stack.instance_variable_get(:@role).logical_id
    assert_equal "ApiFn", stack.instance_variable_get(:@fn).logical_id
    assert_equal "ApiV1DeepRole", stack.instance_variable_get(:@nested).logical_id
  end

  def test_the_ids_are_joined_as_written_never_hashed
    stack = build_stack do
      @lower = RubyCdk::Construct.new(self, "api").resource("role", "AWS::IAM::Role")
      @joined = RubyCdk::Construct.new(self, "Api").resource("Role", "AWS::IAM::Role")
      @plain = resource("ApiRole", "AWS::IAM::Role")
    end

    assert_equal "apirole", stack.instance_variable_get(:@lower).logical_id
    assert_equal "ApiRole", stack.instance_variable_get(:@joined).logical_id
    assert_equal "ApiRole", stack.instance_variable_get(:@plain).logical_id
  end

  def test_a_symbol_id_becomes_a_string
    stack = build_stack { @table = resource(:Table, "AWS::DynamoDB::Table") }

    assert_equal "Table", stack.instance_variable_get(:@table).logical_id
  end

  def test_a_resource_is_registered_in_the_nearest_stack_in_the_order_it_was_created
    app = build_app(env: TEST_ENV)
    first = stack_class { resource("Table", "AWS::DynamoDB::Table") }.new(app, "one")
    second = stack_class do
      resource("Queue", "AWS::SQS::Queue")
      RubyCdk::Construct.new(self, "Api").resource("Role", "AWS::IAM::Role")
    end.new(app, "two")

    assert_equal %w[ Table ], first.resources.map(&:logical_id)
    assert_equal %w[ Queue ApiRole ], second.resources.map(&:logical_id)
    assert_predicate first.resources, :frozen?
  end

  def test_a_resource_needs_a_stack_above_it
    app = build_app
    loose = RubyCdk::Construct.new(app, "Loose")

    error = assert_raises(RubyCdk::UsageError) { app.resource("Table", "AWS::DynamoDB::Table") }

    assert_match(/is created in App, which has no Stack above it/, error.message)
    assert_raises(RubyCdk::UsageError) { loose.resource("Table", "AWS::DynamoDB::Table") }
    assert_raises(RubyCdk::UsageError) { RubyCdk::Cfn::Resource.new(nil, "Table", type: "AWS::DynamoDB::Table") }
    assert_raises(RubyCdk::UsageError) { RubyCdk::Cfn::Resource.new(Object.new, "Table", type: "AWS::DynamoDB::Table") }
    assert_empty app.children.select { |child| child.is_a?(RubyCdk::Cfn::Resource) }
    assert_empty loose.children
  end
end
