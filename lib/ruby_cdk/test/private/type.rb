# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/matching/lib/private/type.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: JavaScript's `typeof` is RubyCdk::Test::Private::Js.typeof.

require_relative "js"

module RubyCdk
  module Test
    module Private
      module_function

      # 'array' for an array, otherwise JavaScript's typeof.
      def get_type(value)
        value.is_a?(Array) ? "array" : Js.typeof(value)
      end
    end
  end
end
