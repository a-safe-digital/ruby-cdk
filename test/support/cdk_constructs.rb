# frozen_string_literal: true

require "support/core_helpers"
require "ruby_cdk/constructs"
require "ruby_cdk/test"

# Shared by the ported construct tests (test/cdk/constructs/, docs/07-testing.md
# section 8). What the ports need over CoreHelpers:
#
#   - with_format_version, the one standing change every whole-template
#     expectation carries: the serialization contract (architecture section 5,
#     D-028) pins AWSTemplateFormatVersion 2010-09-09 on every template, where
#     the CDK writes the key only when templateOptions names one.
#   - stack, the origin's `new Stack()`: an App of its own and one stack, built
#     by the block in the stack's context.
#   - template, the origin's `Template.fromStack(stack)`, from RubyCdk::Test.
module CdkConstructs
  class TestCase < CoreHelpers::TestCase
    Fn = RubyCdk::Fn
    Lazy = RubyCdk::Lazy

    private

    # The CDK's synthesized template, with the format version the
    # serialization contract writes here always added.
    def with_format_version(template)
      { "AWSTemplateFormatVersion" => "2010-09-09" }.merge(template)
    end

    # The origin's `new Stack()`: nothing before it, one stack, whose build is
    # the block. options are the Stack's own keywords.
    def stack(**options, &body)
      RubyCdk::Stack.new(build_app, "Stack", **options, &body)
    end

    # The origin's `Template.fromStack(stack)`.
    def template(stack)
      RubyCdk::Test.template(stack)
    end
  end
end
