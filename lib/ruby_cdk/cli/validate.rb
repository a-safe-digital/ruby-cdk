# frozen_string_literal: true

require "json"
require_relative "failure"
require_relative "selection"

module RubyCdk
  module Cli
    # `validate`: the report of what the schema rules (V1 to V23) say about the
    # templates, without writing anything.
    #
    # Selection is deploy's (packages/aws-cdk/lib/cli/cli.ts:800-819 in
    # aws-cdk-cli at eca1b73d682d7763955bec30ab5dd52bbc4327b6): the app's only
    # stack when nothing is named, a usage error otherwise, --all for every
    # stack. Not deploy's dependency expansion: every stack validates on its
    # own, and bringing dependencies along would report the same template twice
    # (recorded decision).
    #
    # Per stack it runs every phase of architecture section 5 except write
    # (RubyCdk::Synth.run), and then the validation track's own RubyCdk::Validation.validate over
    # the result's template, which is the whole report: every rule, the errors
    # and the warnings apart, the suggestions and AWS's own documentation page
    # for the type an issue is about. Nothing is written: the templates are
    # never handed to the write phase.
    module Validate
      # Section 14: local validation failed.
      VALIDATION_FAILED = 2

      # names are the STACK words. Answers the exit code: 0 when every selected
      # stack is clean of errors, 2 otherwise (warnings are reported, not fatal).
      def self.run(session, names)
        session.register_strict_validators if session.options.strict_types
        selected = Selection.choose(session.stacks, names:, all: session.options.all, command: "validate")
        io = session.io
        io.debug("validate: #{selected.map(&:stack_name).join(", ")}")

        failed = []
        selected.each do |stack|
          result = RubyCdk::Synth.run(stack)
          report = RubyCdk::Validation.validate(result.template, stack_name: stack.stack_name,
            strict_types: !!session.options.strict_types, stateful_types: session.stateful_types)
          extra = unreported(result, report)
          failing = report.errors.any? || result.issues.any?
          if session.options.json
            print_json(io, stack.stack_name, report, extra, failing)
          else
            print_report(io, stack.stack_name, report, extra)
          end
          failed << stack.stack_name if failing
        end
        failed.empty? ? Cli::SUCCESS : VALIDATION_FAILED
      end

      # The report for a person, on standard error: the stack, every error, then
      # every warning prefixed as one, then what the pipeline found that the
      # template's own report cannot see.
      def self.print_report(io, name, report, extra_issues)
        io.say(name)
        report.errors.each do |issue|
          io.say("  #{issue.rule} #{issue.path}: #{issue.message}")
          io.say("    #{issue.hint}") if issue.hint
        end
        report.warnings.each do |warning|
          io.say("  warning #{warning.rule} #{warning.path}: #{warning.message}")
          io.say("    #{warning.hint}") if warning.hint
        end
        extra_issues.each do |issue|
          io.say("  #{issue.rule} #{issue.path}: #{issue.message}")
          io.say("    #{issue.hint}") if issue.hint
        end
        count = "#{report.errors.length} error(s), #{report.warnings.length} warning(s)"
        io.say(extra_issues.any? ? "#{name}: #{count}, #{extra_issues.length} from the tree" : "#{name}: #{count}")
      end

      # What the pipeline found that the report does not hold: the tree's own
      # findings (a duplicate logical ID across sections, for one) that no rule
      # of the template-only report answers. Duplicates of the report are left
      # out, so nothing is printed twice.
      def self.unreported(result, report)
        known = report.issues.map { |issue| [ issue.rule, issue.path, issue.message ] }
        result.issues.reject { |issue| known.include?([ issue.rule, issue.path, issue.message ]) }
      end

      # For --json, one object per stack on standard out, and nothing else there.
      def self.print_json(io, name, report, extra_issues, failed)
        io.result("#{JSON.generate(
          "name" => name,
          "exit_code" => failed ? VALIDATION_FAILED : Cli::SUCCESS,
          "errors" => rows(report.errors + extra_issues),
          "warnings" => rows(report.warnings)
        )}\n")
      end

      def self.rows(issues)
        issues.map do |issue|
          { "rule" => issue.rule, "path" => issue.path, "message" => issue.message, "hint" => issue.hint }.compact
        end
      end
    end
  end
end
