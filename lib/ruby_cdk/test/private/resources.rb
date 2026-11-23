# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/lib/private/resources.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: camelCase to snake_case. getResourceId returns [ resource id, match
#   error ] where the CDK returns an object with one of the two. The deep copy
#   that the CDK takes with a round trip through JSON is Js.deep_copy: the
#   template may hold a Capture, which JSON would destroy. A section or a resource
#   that is not an object reads as empty instead of throwing.

require_relative "../match"
require_relative "../matcher"
require_relative "absent"
require_relative "js"
require_relative "section"

module RubyCdk
  module Test
    module Private
      module_function

      def find_resources(template, type, props = {})
        result = match_section(filter_type(resources_of(template), type), props)
        return {} unless result.match

        result.matches
      end

      # [ resource id, match error ]: one of the two is nil.
      def get_resource_id(template, type, props = {})
        result = match_section(filter_type(resources_of(template), type), props)

        return [ nil, format_section_match_failure("resources with type #{type}", result) ] unless result.match

        resource_ids = result.matches.keys
        if resource_ids.length != 1
          return [ nil, [ "Template has #{resource_ids.length} matches, expected only one.", format_all_matches(result.matches) ].join("\n") ]
        end

        [ resource_ids[0], nil ]
      end

      # The failure message, or nil when every resource of the type matches.
      def all_resources(template, type, props)
        result = match_section(filter_type(resources_of(template), type), props)
        if result.match
          match_count = result.matches.keys.length
          if result.analyzed_count > match_count
            return [ "Template has #{result.analyzed_count} resource(s) with type #{type}, but only #{match_count} match as expected.",
                     format_all_mismatches(result.analyzed, result.matches) ].join("\n")
          end
          nil
        else
          [ "Template has #{result.analyzed_count} resource(s) with type #{type}, but none match as expected.",
            format_all_mismatches(result.analyzed) ].join("\n")
        end
      end

      def all_resources_properties(template, type, props)
        all_resources(with_empty_properties(template, props), type, Match.object_like("Properties" => props))
      end

      def has_resource(template, type, props)
        result = match_section(filter_type(resources_of(template), type), props)
        return if result.match

        format_section_match_failure("resources with type #{type}", result)
      end

      def has_resource_properties(template, type, props)
        has_resource(with_empty_properties(template, props), type, Match.object_like("Properties" => props))
      end

      def count_resources(template, type)
        filter_type(resources_of(template), type).length
      end

      def count_resources_properties(template, type, props)
        amended = with_empty_properties(template, props)
        result = match_section(filter_type(resources_of(amended), type), Match.object_like("Properties" => props))

        result.match ? result.matches.keys.length : 0
      end

      # A copy of the template in which every resource has a Properties key, so
      # that a Properties pattern applies to all of them. Not for Match.absent():
      # adding an empty Properties object would change what it evaluates.
      def with_empty_properties(template, props)
        return template if Matcher.matcher?(props) && props.is_a?(AbsentMatch)

        # The copy must be deep, to avoid modifying the template.
        amended = Js.deep_copy(template)
        section = resources_of(amended)
        Js.object_keys(section).each do |key|
          resource = section[key]
          resource["Properties"] = {} if resource.is_a?(Hash) && !resource.key?("Properties")
        end
        amended
      end

      def resources_of(template)
        section = Js.get(template, "Resources")
        Js.nullish?(section) ? {} : section
      end

      def filter_type(section, type)
        return {} unless section.is_a?(Hash)

        section.select { |_key, resource| resource.is_a?(Hash) && Js.strict_equal?(Js.get(resource, "Type"), type) }
      end
    end
  end
end
