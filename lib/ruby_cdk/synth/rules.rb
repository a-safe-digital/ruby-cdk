# frozen_string_literal: true

require_relative "../errors"
require_relative "../core/ids"
require_relative "../core/stack"

module RubyCdk
  module Synth
    # The two rules that need no knowledge of AWS's resources, and so live with
    # the pipeline. They are registered like every other validator, in synth.rb,
    # and take a Context and return issues.
    module Rules
      # V2: a logical ID holds letters and digits only, and names one thing in
      # the whole stack.
      class LogicalIds
        RULE = "V2"
        SECTIONS = %w[Parameters Mappings Conditions Resources Outputs].freeze

        def call(context)
          issues = []
          first_seen = {}
          template = context.template
          SECTIONS.each do |section|
            names = template[section].is_a?(Hash) ? template[section].keys : []
            names.each do |name|
              path = "#{section}.#{name}"
              issues << Issue.new(
                rule: RULE, path:,
                message: "the logical ID #{name.inspect} must hold letters and digits only",
                hint: "CloudFormation takes no \"_\", \"-\" or \".\" in a logical ID: write #{suggestion(name)}"
              ) unless Core::Ids::LOGICAL_ID_PATTERN.match?(name)

              if (earlier = first_seen[name])
                issues << Issue.new(
                  rule: RULE, path:,
                  message: "the logical ID #{name.inspect} is declared more than once in the stack: in #{earlier} and here",
                  hint: "a logical ID names one thing in the whole stack"
                )
              else
                first_seen[name] = path
              end
            end
          end

          # Two resources with one logical ID leave one key in the template, so the tree is where the second one is.
          context.stack.resources.group_by(&:logical_id).each do |name, resources|
            next if resources.one?

            issues << Issue.new(
              rule: RULE, path: "Resources.#{name}",
              message: "the logical ID #{name.inspect} is that of #{resources.length} resources: #{resources.map(&:path).join(", ")}",
              hint: "a resource inside a construct takes the ids above it in front of its own: give one of them another id"
            )
          end
          issues
        end

        private

        # "my_table" as "MyTable".
        def suggestion(name)
          name.split(/[^A-Za-z0-9]+/).map(&:capitalize).join
        end
      end

      # V13: a stack name starts with a letter, goes on with letters, digits
      # and hyphens, and is at most 128 characters long.
      class StackName
        RULE = "V13"

        def call(context)
          name = context.stack.stack_name
          return [] if Stack::NAME_PATTERN.match?(name) && name.length <= Stack::MAX_NAME_LENGTH

          [
            Issue.new(
              rule: RULE, path: name,
              message: "is not a valid stack name: it must start with a letter, go on with letters, digits and hyphens, and be at most #{Stack::MAX_NAME_LENGTH} characters long",
              hint: "a stack's name is the prefix of App.new(stack_name_prefix:) followed by its id"
            )
          ]
        end
      end
    end
  end
end
