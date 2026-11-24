# frozen_string_literal: true

require_relative "../../schema"
require_relative "rule"
require_relative "template"

module RubyCdk
  module Validation
    # Everything one validation of one template found, in one place: every issue, with
    # the suggestions its rule made and, for an issue about a resource, the page AWS
    # documents the type on. Architecture §6 names this report; the pipeline raises its
    # own ValidationError from the issues, and a command that reports rather than fails
    # prints this.
    class Report
      attr_reader :issues, :errors, :warnings, :template

      # issues: every Issue and Warning of every rule, in order. template: the template
      # they are about.
      def initialize(issues, template)
        @issues = issues.freeze
        @template = template
        @errors = issues.reject { |issue| Validation.warning?(issue) }.freeze
        @warnings = issues.select { |issue| Validation.warning?(issue) }.freeze
      end

      # True when nothing keeps the template from being written.
      def ok?
        errors.empty?
      end

      def empty?
        issues.empty?
      end

      # The issues of one rule, by its id.
      def of_rule(id)
        issues.select { |issue| issue.rule == id }
      end

      # [ [ rule id, issues ], ... ] in the order of the template.
      def by_rule
        RULES.keys.filter_map { |id| found = of_rule(id); [ id, found ] unless found.empty? }
      end

      # [ rule, path, message, hint, documentation_url ], for a command that prints its own.
      def rows
        issues.map do |issue|
          [ issue.rule, issue.path, issue.message, issue.hint, documentation_url(issue) ]
        end
      end

      # The page AWS documents the type of the resource an issue is about, or nil.
      def documentation_url(issue)
        name = issue.path.match(/\AResources\.([A-Za-z0-9]+)\./)&.captures&.first
        type = Template.resource_type(Template.section(template, "Resources")[name])
        type && Schema.type(type)&.documentation_url
      end

      # The whole report, one issue after another:
      #
      #   Validation failed with 2 errors and 1 warning:
      #   V3  Resources.Table.Properties.KeySchem: "KeySchem" is not a property of AWS::DynamoDB::Table; did you mean KeySchema?
      #       write the CloudFormation name, or in snake_case: key_schema
      #       https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-dynamodb-table.html
      def to_s
        return "Validation passed: nothing to report.\n" if empty?

        [ summary, *issues.flat_map { |issue| lines_of(issue) } ].join("\n") + "\n"
      end

      private

      def summary
        return "Validation passed with #{count(warnings.size, "warning")}:" if errors.empty?

        "Validation failed with #{count(errors.size, "error")}#{warnings.empty? ? "" : " and #{count(warnings.size, "warning")}"}:"
      end

      def count(number, word)
        "#{number} #{word}#{number == 1 ? "" : "s"}"
      end

      def lines_of(issue)
        url = documentation_url(issue)
        lines = [ "#{issue.rule}  #{issue.path}: #{issue.message}#{Validation.warning?(issue) ? " (warning)" : ""}" ]
        lines << "    #{issue.hint}" if issue.hint
        lines << "    #{url}" if url && !issue.hint.to_s.include?(url)
        lines
      end
    end
  end
end
