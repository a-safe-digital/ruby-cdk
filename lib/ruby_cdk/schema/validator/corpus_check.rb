# frozen_string_literal: true

require "json"
require_relative "../../schema"
require_relative "../validator"

module RubyCdk
  module Validation
    # The corpus check (docs/07-testing.md §6): validates every template of a directory
    # and says what was found. The templates are the CDK's own, synthesized and accepted
    # by CloudFormation, so an error of any rule is a false positive: a bug in the model
    # or in a rule. A warning is one the rule was made to give — an unknown type, a
    # stack that deletes what it holds — and the check counts them by rule so that a run
    # can be compared with the last.
    #
    # The safe defaults of architecture §7 belong to the tree, not to this component, so
    # the caller hands the stateful types in (stateful_types:) the same way the umbrella
    # hands them to rule V15.
    class CorpusCheck
      # What one template answered.
      Finding = Data.define(:path, :errors, :warnings)

      attr_reader :findings, :templates, :unparseable

      # templates: every *.template.json under root, sorted. stateful_types: the types
      # architecture §7 retains, as V15 takes them.
      def initialize(root, stateful_types:)
        @stateful_types = stateful_types
        @templates = Dir[File.join(root, "**", "*.json")].sort
        @findings = []
        @unparseable = []
        check_all
      end

      # Every error of every template, with its file: each one is a false positive to fix
      # or to explain in known_false_positives.yml.
      def errors
        findings.flat_map { |finding| finding.errors.map { |issue| [ finding.path, issue ] } }
      end

      # Warnings by rule id: { "V1" => 220, "V15" => 103 }.
      def warnings_by_rule
        findings.flat_map { |finding| finding.warnings }.each_with_object(Hash.new(0)) do |issue, counts|
          counts[issue.rule] += 1
        end
      end

      # One line per file with something in it, as the weekly report prints it.
      def to_s
        lines = findings.select { |finding| finding.errors.any? || finding.warnings.any? }.map do |finding|
          "#{path_of(finding.path)}: #{finding.errors.size} errors, #{finding.warnings.size} warnings"
        end
        [ "#{templates.size} templates, #{unparseable.size} unparseable, #{errors.size} errors, " \
          "#{warnings_by_rule.sum { |_rule, count| count }} warnings #{warnings_by_rule.sort.map { |rule, count| "#{rule}=#{count}" }.join(" ")}",
          *lines ].join("\n")
      end

      private

      def check_all
        templates.each do |path|
          template = read(path)
          next @unparseable << path if template.nil?

          report = Validation.validate(template, stateful_types: @stateful_types)
          @findings << Finding.new(path, report.errors, report.warnings)
        end
      end

      def read(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      def path_of(path)
        path.delete_prefix("#{File.dirname(File.dirname(path))}/")
      end
    end
  end
end
