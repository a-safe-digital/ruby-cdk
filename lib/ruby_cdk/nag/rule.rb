# frozen_string_literal: true

require_relative "report"
require_relative "values"

module RubyCdk
  module Nag
    # A rule whose definition does not hold together: an id of the wrong shape,
    # a severity that does not exist. It is a mistake in this gem, never in a template.
    class DefinitionError < RubyCdk::Error; end

    # A rule: an id, a description, a severity, the resource types it applies
    # to, and the audit that returns violations for one resource.
    #
    #   class EbsVolumeEncrypted < Rule
    #     id          "RC-EBS-001"
    #     description "EBS volume is encrypted"
    #     severity    :high
    #     applies_to  "AWS::EC2::Volume"
    #
    #     def audit
    #       check("Properties.Encrypted") do
    #         violate("Properties.Encrypted", "is not encrypted: set Encrypted to true") unless values.boolean("Properties.Encrypted") == true
    #       end
    #     end
    #   end
    #
    # An instance is one rule applied to one resource. Its audit reads values
    # through values (a Reader), inside check blocks. A check that meets a
    # dynamic value ends there and is counted as skipped; the other checks of
    # the same rule on the same resource still run.
    class Rule
      # Every rule id has this shape.
      ID_PATTERN = /\ARC-[A-Z0-9]+-\d{3}\z/
      RESOURCE_TYPE_PATTERN = /\AAWS::[A-Za-z0-9]+::[A-Za-z0-9]+\z/
      UNSET = Object.new.freeze

      # What one rule found on one resource.
      Outcome = Data.define(:violations, :skipped)

      class << self
        # --- the definition, written once in the body of a rule's class.

        # The id, "RC-<AREA>-<NNN>". With an argument, sets it.
        def id(value = UNSET)
          @id = value unless value.equal?(UNSET)
          @id
        end

        # What the rule demands of a resource, in one line. With an argument, sets it.
        def description(value = UNSET)
          @description = value unless value.equal?(UNSET)
          @description
        end

        # :high, :medium or :low. With an argument, sets it.
        def severity(value = UNSET)
          @severity = value unless value.equal?(UNSET)
          @severity
        end

        # The resource types the rule applies to, as written with applies_to.
        attr_reader :resource_types

        # Sets the resource types the rule applies to.
        def applies_to(*types)
          @resource_types = types.freeze unless types.empty?
        end

        # True when the rule is written for this resource type.
        def applies_to?(type)
          Array(resource_types).include?(type)
        end

        # Everything wrong with the definition. Empty when it holds together.
        def definition_problems
          problems = []
          problems << "id #{id.inspect} does not have the shape RC-<AREA>-<NNN>" unless ID_PATTERN.match?(id.to_s)
          problems << "has no description" if description.to_s.strip.empty?
          problems << "severity #{severity.inspect} is not one of #{SEVERITIES.inspect}" unless SEVERITIES.include?(severity)
          unless Array(resource_types).any? { |type| RESOURCE_TYPE_PATTERN.match?(type) } || decides_applicability_itself?
            problems << "names no resource type (applies_to) and does not decide applicability itself (applicable?)"
          end
          problems
        end

        private

        def decides_applicability_itself?
          instance_method(:applicable?).owner != Rule
        end
      end

      attr_reader :resource, :config

      # resource: the resource as written in the template, a Hash. logical_id:
      # its key under Resources. config: the Config of this run, for the rules
      # that take a list from it.
      def initialize(resource, logical_id:, config:)
        @resource = resource
        @logical_id = logical_id
        @config = config
        @values = Reader.new(resource)
        @violations = []
        @skipped = []
      end

      # The resource's Type.
      def type
        @resource.is_a?(Hash) ? @resource["Type"] : nil
      end

      # False when the rule has nothing to say about this resource.
      def applicable?
        self.class.applies_to?(type)
      end

      # Runs the rule over its resource. Never raises: a value that is not a
      # literal, and a fault inside the rule, both end as a Skipped record.
      def run
        begin
          audit
        rescue Undecided => e
          @skipped << skipped_record(e.path, e.reason)
        rescue StandardError => e
          @skipped << skipped_record("", "the rule failed: #{e.class}: #{e.message}")
        end
        Outcome.new(violations: @violations, skipped: @skipped)
      end

      # The rule itself. Reads through values, inside check blocks.
      def audit
        raise NotImplementedError, "#{self.class} does not audit anything"
      end

      protected

      # The Reader over the resource.
      def values
        @values
      end

      # One check, at one path. Runs the block. When a value the block needs is
      # not a literal, the block ends, a Skipped is recorded for path, and
      # check returns nil. Otherwise it returns what the block returned.
      def check(path)
        yield
      rescue Undecided => e
        @skipped << skipped_record(e.path, e.reason)
        nil
      end

      # Records a violation at path with a message that says what to change.
      def violate(path, message)
        @violations << Violation.new(rule: self.class.id, severity: self.class.severity, logical_id: @logical_id, resource_type: type, path: path,
          message: message)
      end

      # Ends the current check as undecided, with the reason.
      def undecided(path, reason)
        raise Undecided.new(path, reason)
      end

      private

      def skipped_record(path, reason)
        Skipped.new(rule: self.class.id, logical_id: @logical_id, resource_type: type, path: path, reason: reason)
      end
    end
  end
end
