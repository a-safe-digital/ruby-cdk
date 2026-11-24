# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/matching/lib/private/matchers/absent.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: nothing in behaviour. Undefined is RubyCdk::Test::UNDEFINED.

require_relative "js"
require_relative "../matcher"

module RubyCdk
  module Test
    module Private
      # The matcher behind Match.absent().
      class AbsentMatch < Matcher
        attr_reader :name

        def initialize(name)
          @name = name
        end

        def test(actual)
          result = MatchResult.new(actual)
          unless actual.equal?(UNDEFINED)
            result.record_failure(matcher: self, path: [], message: "Received #{Js.string(actual)}, but key should be absent")
          end
          result
        end
      end
    end
  end
end
