# frozen_string_literal: true

require "support/core_helpers"

# Shared by the ported stack.test.ts and resource.test.ts
# (test/cdk/core/). What the two ports need over CoreHelpers:
#
#   - with_format_version, the one standing change every template expectation
#     here carries: the serialization contract (architecture §5, D-028) pins
#     AWSTemplateFormatVersion 2010-09-09 and writes it on every template,
#     where the CDK writes the key only when templateOptions names one.
#   - stack, the origin's `new Stack()`: an App of its own and one stack,
#     built by the block in the stack's context.
module CdkCore
  class TestCase < CoreHelpers::TestCase
    Fn = RubyCdk::Fn
    Lazy = RubyCdk::Lazy

    private

    # The CDK's toCloudFormation output, with the format version the
    # serialization contract writes here always added.
    def with_format_version(template)
      { "AWSTemplateFormatVersion" => "2010-09-09" }.merge(template)
    end

    # The origin's `new Stack()`: nothing before it, one stack, whose build is
    # the block. options are the Stack's own keywords.
    def stack(**options, &body)
      RubyCdk::Stack.new(build_app, "Stack", **options, &body)
    end
  end
end
