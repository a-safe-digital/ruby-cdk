# frozen_string_literal: true

require_relative "config"
require_relative "rule"

module RubyCdk
  module Nag
    # Runs the rule pack over a template, a plain Hash in CloudFormation
    # syntax, and applies the suppressions.
    #
    # Ported from cdk-nag (cdklabs/cdk-nag, commit
    # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0), src/nag-pack.ts:
    # every rule runs on every resource; a finding is dropped when the rule is
    # acknowledged; a rule that cannot read a value is neither passed nor
    # forgotten; and an acknowledgement is written into the resource's
    # CloudFormation Metadata by WriteNagSuppressionsToCloudFormationAspect,
    # as cdk_nag: { rules_to_suppress: [{ id, reason }] }.
    # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
    # SPDX-License-Identifier: Apache-2.0
    #
    # What changed: a value that is an intrinsic makes the check a Skipped
    # record, counted as not evaluated, where the source reports the rule as
    # failed with "Rule threw an error during validation". The key of the
    # suppression is "RubyCdk::Nag" and its list "RulesToSuppress", as the
    # wave card names them. Acknowledgements are read on the resource alone: a
    # template has no construct tree to walk up, so a whole scope cannot be
    # acknowledged in it. An acknowledgement without a reason is ignored, with
    # a warning, where the source keeps it. A finding is acknowledged by its
    # rule on the resource, or by a suppression of the configuration file whose
    # applies_to matches the resource; "RuleId[FindingId]" is not ported.
    class Engine
      RESOURCES = "Resources"
      METADATA = "Metadata"
      SUPPRESSIONS = "RubyCdk::Nag"
      RULES_TO_SUPPRESS = "RulesToSuppress"
      ID = "Id"
      REASON = "Reason"
      SUPPRESSION_KEYS = [ ID, REASON ].freeze

      attr_reader :rules

      # rules: the rule classes to run. Raises DefinitionError when one of them
      # is malformed, or when two share an id: that is a fault in this gem.
      def initialize(rules: Rules::ALL)
        @rules = rules
        @rules.each do |rule|
          problems = rule.definition_problems
          raise DefinitionError, "#{rule}: #{problems.join("; ")}" unless problems.empty?
        end

        shared = @rules.map(&:id).tally.select { |_, count| count > 1 }.keys
        raise DefinitionError, "several rules share an id: #{shared.join(", ")}" unless shared.empty?
      end

      # One template, one Report.
      #
      # config: a Config, or a Hash written like nag.yml; nil is the default.
      # locations: where the stack is, its name and its path, which the globs
      # of paths_to_suppress are matched against.
      def check(template, config: nil, locations: [])
        config = Config.coerce(config)
        violations = []
        skipped = []
        suppressed = []
        warnings = []
        path_glob = config.suppressed_path(locations)

        resources_in(template).each do |logical_id, resource|
          acknowledgements = suppressions_in(resource, logical_id, warnings)

          @rules.each do |rule_class|
            next unless config.rule_enabled?(rule_class.id)

            rule = rule_class.new(resource, logical_id: logical_id, config: config)
            next unless rule.applicable?

            outcome = rule.run
            skipped.concat(outcome.skipped)
            outcome.violations.each do |violation|
              suppression = acknowledgements[violation.rule] || config.suppression_for(violation.rule, logical_id, violation.resource_type)
              reason = if suppression
                suppression.reason
              elsif path_glob
                "the stack matches paths_to_suppress #{path_glob.inspect} in #{Config::FILE}"
              end

              if reason
                suppressed << Suppressed.new(rule: violation.rule, severity: violation.severity, logical_id: violation.logical_id,
                  resource_type: violation.resource_type, path: violation.path, message: violation.message, reason: reason)
              else
                violations << violation
              end
            end
          end
        end

        Report.new(violations: violations, skipped: skipped, suppressed: suppressed, warnings: warnings)
      end

      private

      # Every resource of the template that is a mapping, in the order written.
      def resources_in(template)
        return [] unless template.is_a?(Hash)

        resources = template[RESOURCES]
        return [] unless resources.is_a?(Hash)

        resources.select { |_logical_id, resource| resource.is_a?(Hash) }
      end

      # The acknowledgements written in the resource's Metadata: { rule id =>
      # Suppression }. One that is not shaped right, that names no rule, or
      # that has no reason is ignored, and a Warning says so.
      def suppressions_in(resource, logical_id, warnings)
        metadata = resource[METADATA]
        return {} unless metadata.is_a?(Hash)

        entries = metadata[SUPPRESSIONS]
        return {} unless entries.is_a?(Hash)

        list = entries[RULES_TO_SUPPRESS]
        return {} unless list.is_a?(Array)

        found = {}
        list.each_with_index do |entry, index|
          at = "Resources/#{logical_id}/#{METADATA}/#{SUPPRESSIONS}/#{RULES_TO_SUPPRESS}[#{index}]"
          unless entry.is_a?(Hash) && entry.keys.all? { |key| SUPPRESSION_KEYS.include?(key) }
            warnings << Warning.new(location: at, message: "is not written as {\"Id\" => <rule>, \"Reason\" => <why>}, and is ignored")
            next
          end

          id = entry[ID]
          unless id.is_a?(String) && Rules.ids.include?(id)
            warnings << Warning.new(location: at, message: "names #{id.inspect}, and no rule has that id; it is ignored")
            next
          end

          reason = entry[REASON]
          unless reason.is_a?(String) && !reason.strip.empty?
            warnings << Warning.new(location: at, message: "suppresses #{id} without a reason, and is ignored: a suppression says why it is safe")
            next
          end

          found[id] ||= Suppression.new(id: id, reason: reason.strip, applies_to: nil)
        end
        found
      end
    end
  end
end
