# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# The tree: scope, id, path, children, and what the tree refuses.
class CoreConstructTest < CoreHelpers::TestCase
  class Group < RubyCdk::Construct
    attr_reader :prepared_after

    def prepare
      @prepared_after = children.map(&:path)
    end
  end

  def test_the_root_is_app_and_every_path_runs_down_from_it
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")
    group = Group.new(stack, "Api")
    node = Group.new(group, "V1")

    assert_equal "App", app.path
    assert_equal "App", app.id
    assert_nil app.scope
    assert_equal "App/blog", stack.path
    assert_equal "App/blog/Api", group.path
    assert_equal "App/blog/Api/V1", node.path
    assert_same stack, group.scope
    assert_same group, node.scope
    assert_equal "V1", node.id
  end

  def test_children_are_kept_in_the_order_they_were_created_and_cannot_be_changed_from_outside
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")
    second = RubyCdk::Construct.new(stack, "Second")
    first = RubyCdk::Construct.new(stack, "First")

    assert_equal [ second, first ], stack.children
    assert_equal [ stack ], app.children
    assert_predicate stack.children, :frozen?
    assert_raises(FrozenError) { stack.children << first }
    assert_equal 2, stack.children.length
  end

  def test_an_id_may_be_a_string_or_a_symbol_and_is_kept_as_a_string
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")

    assert_equal "Role", RubyCdk::Construct.new(stack, :Role).id
    assert_equal "App/blog/Role", stack.children.last.path
    assert_equal "a-B_9", RubyCdk::Construct.new(stack, "a-B_9").id
    assert_equal "a", RubyCdk::Construct.new(stack, "a").id
  end

  def test_an_id_holds_letters_digits_underscores_and_hyphens_and_at_least_one_of_them
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")
    [ "", "my role", "role.name", "a:b", "role\n", "rôle", " ", "a b" ].each do |id|
      error = assert_raises(RubyCdk::UsageError, "#{id.inspect} should be refused") { RubyCdk::Construct.new(stack, id) }

      assert_match(/#{Regexp.escape("The id #{id.inspect} under App\/blog is not valid")}/, error.message)
    end
    assert_empty stack.children
  end

  def test_an_id_is_at_most_255_characters
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")

    assert_equal 255, RubyCdk::Construct.new(stack, "a" * 255).id.length
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Construct.new(stack, "a" * 256) }

    assert_match(/longer than 255 characters/, error.message)
  end

  def test_an_id_that_is_not_a_string_or_a_symbol_is_refused
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")

    [ nil, 42, Object.new, [ "a" ] ].each do |id|
      error = assert_raises(RubyCdk::UsageError) { RubyCdk::Construct.new(stack, id) }

      assert_match(/must be a String or a Symbol, got #{Regexp.escape(id.inspect)}/, error.message)
    end
  end

  def test_two_children_of_one_node_cannot_have_the_same_id
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")
    group = RubyCdk::Construct.new(stack, "Api")
    RubyCdk::Construct.new(group, "Role")

    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Construct.new(group, "Role") }

    assert_equal 'There is already a construct with id "Role" in App/blog/Api', error.message
    assert_raises(RubyCdk::UsageError) { RubyCdk::Stack.new(app, "blog") }
    assert_raises(RubyCdk::UsageError) { RubyCdk::Construct.new(group, :Role) }
    assert_equal 1, group.children.length
  end

  def test_the_same_id_under_two_different_nodes_is_fine
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")
    one = RubyCdk::Construct.new(stack, "One")
    two = RubyCdk::Construct.new(stack, "Two")

    assert_equal "One/Role", RubyCdk::Construct.new(one, "Role").path.delete_prefix("App/blog/")
    assert_equal "Two/Role", RubyCdk::Construct.new(two, "Role").path.delete_prefix("App/blog/")
  end

  def test_a_scope_is_an_app_a_stack_or_a_construct
    [ nil, Object.new, "App" ].each do |scope|
      assert_raises(RubyCdk::UsageError) { RubyCdk::Construct.new(scope, "Node") }
      assert_raises(RubyCdk::UsageError) { Group.new(scope, "Node") }
    end
  end

  def test_add_checks_the_id_and_what_it_is_given_and_returns_the_node
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")

    assert_raises(RubyCdk::UsageError) { stack.add(Object.new) }
    node = Group.allocate
    node.instance_variable_set(:@id, "bad id")
    assert_raises(RubyCdk::UsageError) { stack.add(node) }
    assert_empty stack.children
  end

  def test_stack_is_the_nearest_enclosing_stack_and_nil_when_there_is_none
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")
    group = RubyCdk::Construct.new(stack, "Api")
    node = RubyCdk::Construct.new(group, "Role")
    loose = RubyCdk::Construct.new(app, "Loose")

    assert_nil app.stack
    assert_same stack, stack.stack
    assert_same stack, group.stack
    assert_same stack, node.stack
    assert_nil loose.stack
  end

  def test_fn_is_reachable_from_any_construct
    assert_same RubyCdk::Fn, RubyCdk::Construct::Fn
    assert_same RubyCdk::Fn, RubyCdk::Stack::Fn

    stack = stack_class { @reference = Fn.ref("Table") }.new(build_app, "blog")

    assert_equal({ "Ref" => "Table" }, stack.instance_variable_get(:@reference))
  end

  def test_the_prepare_hook_runs_children_first_and_once_per_node
    app = build_app
    stack = RubyCdk::Stack.new(app, "blog")
    group = Group.new(stack, "Api")
    role = Group.new(group, "Role")
    table = Group.new(stack, "Table")
    stack.prepare_tree

    assert_equal [ "App/blog/Api/Role" ], group.prepared_after
    assert_equal [], role.prepared_after
    assert_equal [], table.prepared_after

    group.instance_variable_set(:@prepared_after, nil)
    role.instance_variable_set(:@prepared_after, nil)
    table.instance_variable_set(:@prepared_after, nil)
    stack.prepare_tree

    assert_nil group.prepared_after
    assert_nil role.prepared_after
    assert_nil table.prepared_after
  end

  def test_a_prepare_hook_may_add_a_resource_and_it_is_not_added_twice
    app = build_app
    klass = Class.new(RubyCdk::Stack) do
      def build
        RubyCdk::Construct.new(self, "Api")
      end

      def prepare
        resource("Implicit#{stack.resources.length}", "AWS::SNS::Topic")
      end
    end
    stack = klass.new(app, "blog")

    assert_equal 1, stack.to_template["Resources"].length

    stack.prepare_tree
    stack.prepare_tree
    assert_equal 1, stack.to_template["Resources"].length
  end
end
