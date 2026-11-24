# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/lib/private/outputs.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: camelCase to snake_case, and nothing in behaviour. The functions are
#   module functions of Private.

require_relative "js"
require_relative "section"

module RubyCdk
  module Test
    module Private
      module_function

      def find_outputs(template, logical_id, props = {})
        result = match_section(filter_logical_id(outputs_of(template), logical_id), props)
        return {} unless result.match

        result.matches
      end

      def has_output(template, logical_id, props)
        result = match_section(filter_logical_id(outputs_of(template), logical_id), props)
        return if result.match

        format_section_match_failure("outputs named #{logical_id}", result)
      end

      def outputs_of(template)
        section = Js.get(template, "Outputs")
        Js.nullish?(section) ? {} : section
      end
    end
  end
end
