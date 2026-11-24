# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/lib/private/cyclic.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: camelCase to snake_case. A Set is a list without doubles, in the
#   order of insertion, as there. The literal fragments of an Fn::Sub string,
#   which carry no logical ID, are not collected. A resource that is not an object
#   has no dependencies here, where JavaScript would throw.

require_relative "error"
require_relative "js"

module RubyCdk
  module Test
    module Private
      module_function

      # Check a template for cyclic dependencies.
      #
      # This will make sure that we don't happily validate templates in unit tests
      # that wouldn't deploy to CloudFormation anyway.
      def check_template_for_cyclic_dependencies(template)
        resources = Js.get(template, "Resources")
        resources = {} if Js.nullish?(resources)
        logical_ids = Js.object_keys(resources)

        dependencies = {}
        Js.object_keys(resources).each do |logical_id|
          dependencies[logical_id] = find_resource_dependencies(resources[logical_id]).select { |id| logical_ids.include?(id) }
        end

        # We will now progressively remove entries from the map of 'dependencies' that have
        # 0 elements in them. If we can't do that anymore and the map isn't empty, we
        # have a cyclic dependency.
        until dependencies.empty?
          free = dependencies.select { |_logical_id, deps| deps.empty? }.keys
          if free.empty?
            # Oops!
            cycle = find_cycle(dependencies)

            cycle_resources = cycle.to_h { |logical_id| [ logical_id, Js.get(resources, logical_id) ] }

            Kernel.raise AssertionError,
              "Template is undeployable, these resources have a dependency cycle: #{cycle.join(" -> ")}:\n\n#{Js.json(cycle_resources, 2)}"
          end

          free.each do |logical_id|
            dependencies.each_value { |deps| deps.delete(logical_id) }
            dependencies.delete(logical_id)
          end
        end
        nil
      end

      def find_resource_dependencies(resource)
        return [] unless resource.is_a?(Hash)

        depends_on = Js.get(resource, "DependsOn")
        depends_on = [] if Js.nullish?(depends_on)
        declared = depends_on.is_a?(Array) ? depends_on : [ depends_on ]
        (declared + find_expression_dependencies(Js.get(resource, "Properties"))).uniq
      end

      def find_expression_dependencies(value)
        found = []
        recurse_expression(value, found)
        found
      end

      def recurse_expression(value, found)
        return if Js.nullish?(value)

        value.each { |element| recurse_expression(element, found) } if value.is_a?(Array)

        if Js.object?(value)
          entries = Js.entries(value)
          keys = entries.map(&:first)
          if keys.length == 1 && keys[0] == "Ref"
            found << entries[0][1]
          elsif keys.length == 1 && keys[0] == "Fn::GetAtt"
            argument = entries[0][1]
            found << argument[0] if argument.is_a?(Array) || argument.is_a?(String)
          elsif keys.length == 1 && keys[0] == "Fn::Sub"
            argument = entries[0][1]
            pattern = argument.is_a?(Array) ? argument[0] : argument

            # pattern should always be a string, but we've encountered some cases in which
            # it isn't. Better safeguard.
            found.concat(logical_ids_in_sub_string(pattern)) if pattern.is_a?(String)

            context_dict = argument.is_a?(Array) ? argument[1] : nil
            recurse_expression(context_dict, found) if Js.object?(context_dict)
          else
            entries.each { |_key, element| recurse_expression(element, found) }
          end
        end
        nil
      end

      # Return the logical IDs found in an Fn::Sub string.
      def logical_ids_in_sub_string(pattern)
        analyze_sub_pattern(pattern).filter_map do |fragment|
          fragment[0] == :literal ? nil : fragment[1]
        end
      end

      # :ref and :getatt fragments carry a logical ID; :literal ones do not.
      def analyze_sub_pattern(pattern)
        text = "#{pattern}"
        fragments = []

        search_from = 0
        while (placeholder_start = text.index("${", search_from))
          if text[placeholder_start + 2] == "!" # "${!" means "don't actually substitute"
            search_from = placeholder_start + 3
            next
          end

          placeholder_end = text.index("}", placeholder_start + 2)
          break if placeholder_end.nil?

          placeholder = text[(placeholder_start + 2)...placeholder_end] || ""

          if placeholder.include?(".")
            logical_id, = placeholder.split(".")
            fragments << [ :getatt, logical_id ]
          else
            fragments << [ :ref, placeholder ]
          end

          search_from = placeholder_end + 1
        end

        fragments
      end

      # Find cycles in a graph. Not the fastest, but effective and should be rare.
      def find_cycle(deps)
        deps.each_key do |node|
          cycle = cycle_from(node, [ node ], deps)
          return cycle if cycle
        end
        Kernel.raise AssertionError, "No cycle found. Assertion failure!"
      end

      def cycle_from(node, path, deps)
        (deps[node] || []).each do |dependency|
          return path + [ dependency ] if path.include?(dependency)

          cycle = cycle_from(dependency, path + [ dependency ], deps)
          return cycle if cycle
        end
        nil
      end
    end
  end
end
