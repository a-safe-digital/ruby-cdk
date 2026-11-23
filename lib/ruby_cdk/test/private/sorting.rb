# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/matching/lib/private/sorting.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: a comparator built from a key block, for Array#sort. Strings compare
#   with localeCompare there, which pure Ruby has no ICU for; the approximation is
#   Js.locale_compare.

require_relative "js"

module RubyCdk
  module Test
    module Private
      module_function

      # A comparator on a key block that returns numbers or strings: by the first
      # key that differs, then by the longer key.
      def sort_key_comparator(&key)
        ->(left, right) do
          left_keys = key.call(left)
          right_keys = key.call(right)
          left_keys.zip(right_keys).each do |left_key, right_key|
            difference = if left_key.is_a?(Numeric) && right_key.is_a?(Numeric)
              left_key - right_key
            elsif left_key.is_a?(String) && right_key.is_a?(String)
              Js.locale_compare(left_key, right_key)
            else
              0
            end
            return difference unless difference.zero?
          end
          right_keys.length - left_keys.length
        end
      end
    end
  end
end
