# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/matching/lib/private/error.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: the parent class. There it is Error. Here it is decided when this
#   file loads: Minitest::Assertion when Minitest is already loaded, so that a
#   failed assertion is reported as a failure and not as an error in a Minitest
#   run; StandardError otherwise, so that this file loads alone. Require
#   "minitest/autorun" before "ruby_cdk/test". Under Minitest the class descends
#   from Exception, so a bare `rescue` does not catch it, as for any other
#   Minitest assertion failure. The class is built with Class.new because its
#   parent is not known until load time. The symbol that marks the class there is
#   not reproduced: `is_a?(RubyCdk::Test::AssertionError)` answers the same question.

module RubyCdk
  module Test
    MINITEST_ASSERTION = if Object.const_defined?("Minitest", false) &&
                            Object.const_get("Minitest", false).const_defined?(:Assertion, false)
      Object.const_get("Minitest", false).const_get(:Assertion, false)
    end
    private_constant :MINITEST_ASSERTION

    # Thrown from the assertions module when an assertion fails. Assertion errors
    # are directly connected to an assertion a user wrote.
    #
    # Not every error of the module is an AssertionError. The CDK says a wrong
    # precondition (a matcher used where it cannot be) is better reported another
    # way, but raises this class for it; so does this port, for that and for a
    # template with a dependency cycle. Where JavaScript itself throws a TypeError
    # (a null where an object was needed), so does this port.
    AssertionError = Class.new(MINITEST_ASSERTION || StandardError) do
      # The time the error was thrown, as an ISO 8601 timestamp.
      attr_reader :time

      def type
        "assertion"
      end

      def initialize(msg = nil)
        super(msg)
        @time = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
      end
    end
  end
end
