# frozen_string_literal: true

module RubyCdk
  module Nag
    # The severities a rule can have, from the most to the least serious.
    SEVERITIES = %i[high medium low].freeze

    # How serious each severity is. A threshold fails a violation of the same rank or higher.
    SEVERITY_RANK = { high: 3, medium: 2, low: 1 }.freeze

    # One finding of one rule on one resource.
    #
    # path locates the finding inside the resource, as the keys are written in the
    # template: "Properties.Encrypted", "Properties.SecurityGroupIngress[1].CidrIp",
    # "DeletionPolicy".
    Violation = Data.define(:rule, :severity, :logical_id, :resource_type, :path, :message)

    # A check a rule could not finish. reason says what stood in the way, for
    # example "Properties.Encrypted is {\"Ref\"=>\"Encrypted\"}, a dynamic value".
    # A skipped check is neither a pass nor a failure: it is reported as not evaluated.
    Skipped = Data.define(:rule, :logical_id, :resource_type, :path, :reason)

    # A violation that a suppression covered. The finding is kept, with the
    # reason of the suppression, so that a report shows what was hidden.
    Suppressed = Data.define(:rule, :severity, :logical_id, :resource_type, :path, :message, :reason)

    # Something that was ignored instead of acted upon, such as a suppression
    # without a reason. location names the file or the resource it was found in.
    Warning = Data.define(:location, :message)

    # What one template's check found: every violation, every check that could
    # not be decided, every finding a suppression covered, and every warning.
    class Report
      attr_reader :violations, :skipped, :suppressed, :warnings

      # violations: Array<Violation>. skipped: Array<Skipped>. suppressed: Array<Suppressed>. warnings: Array<Warning>.
      def initialize(violations: [], skipped: [], suppressed: [], warnings: [])
        @violations = violations.freeze
        @skipped = skipped.freeze
        @suppressed = suppressed.freeze
        @warnings = warnings.freeze
      end

      # True when a violation is at threshold or above: fails?(:medium) is true
      # for a medium or a high violation, and false when only low ones were found.
      # threshold is :high, :medium or :low.
      def fails?(threshold)
        rank = SEVERITY_RANK.fetch(threshold) { raise ArgumentError, "threshold must be one of #{SEVERITIES.inspect}, got #{threshold.inspect}" }
        @violations.any? { |violation| SEVERITY_RANK.fetch(violation.severity) >= rank }
      end

      # The severity of the most serious violation, or nil when there is none.
      def worst_severity
        @violations.map { |violation| SEVERITY_RANK.fetch(violation.severity) }.max&.then { |rank| SEVERITY_RANK.key(rank) }
      end

      # The violations of each rule: { rule id => Array<Violation> }, in rule order.
      def by_rule
        @violations.group_by(&:rule)
      end

      # The number of checks that could not be decided.
      def skipped_count
        @skipped.length
      end

      # True when nothing was found at all: no violation, nothing suppressed, nothing skipped, no warning.
      def empty?
        @violations.empty? && @skipped.empty? && @suppressed.empty? && @warnings.empty?
      end

      # One report that holds everything these reports hold, in the order given.
      def self.merge(reports)
        reports = reports.to_a
        Report.new(
          violations: reports.flat_map(&:violations),
          skipped: reports.flat_map(&:skipped),
          suppressed: reports.flat_map(&:suppressed),
          warnings: reports.flat_map(&:warnings)
        )
      end
    end
  end
end
