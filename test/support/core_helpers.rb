# frozen_string_literal: true

require "tmpdir"
require "ruby_cdk/cfn"
require "ruby_cdk/synth"

# Shared by the tests of the tree, of the L1 resource and of the pipeline: a
# fresh App registry and a temporary directory for each test.
module CoreHelpers
  class TestCase < Minitest::Test
    # So that a test reads like a Stack subclass: Fn.ref, not RubyCdk::Fn.ref.
    Fn = RubyCdk::Fn
    Lazy = RubyCdk::Lazy

    TEST_ENV = RubyCdk::Env.new(account: "111122223333", region: "eu-west-1")

    def setup
      RubyCdk::App.reset!
      @dir = Dir.mktmpdir("ruby-cdk-test")
    end

    def teardown
      RubyCdk::App.reset!
      FileUtils.remove_entry(@dir) if @dir
    end

    private

    attr_reader :dir

    # An App that writes under the test's directory.
    def build_app(**options, &block)
      RubyCdk::App.new(out_dir: File.join(@dir, "out"), **options, &block)
    end

    # A Stack subclass whose build runs the block in the stack's context.
    def stack_class(&body)
      raise ArgumentError, "stack_class needs the body of build" unless body

      Class.new(RubyCdk::Stack) do
        define_method(:build) { instance_eval(&body) }
      end
    end

    # One stack in an App with the test env: a plain Stack, or one built by the block.
    def build_stack(id = "blog", app_options: {}, stack_options: {}, &body)
      app = build_app(env: TEST_ENV, **app_options)
      klass = body ? stack_class(&body) : RubyCdk::Stack
      klass.new(app, id, **stack_options)
    end
  end
end
