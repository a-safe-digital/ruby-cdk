# frozen_string_literal: true

require_relative "errors"

module RubyCdk
  module Deploy
    # The parameter values a deploy sends, and whether they differ from the
    # ones deployed. The rule is the CDK's (ParameterValues in its CLI): a value
    # that is given wins, then the template's default; a parameter that has
    # neither is an error; a value for a parameter the template does not declare
    # is passed on, and CloudFormation reports the typo.
    class Parameters
      # CloudFormation resolves these at deploy time, so they can change with no local sign of it.
      SSM_TYPE_PREFIX = "AWS::SSM::Parameter::"

      # { parameter key => value }: what the stack will use, defaults included.
      attr_reader :values
      # What goes to create_change_set: an Array of { parameter_key:, parameter_value: }.
      attr_reader :api

      # template is parsed; overrides is { key => value }.
      def initialize(template, overrides = {})
        section = template["Parameters"]
        declared = section.is_a?(Hash) ? section : {}
        given = overrides.to_h.transform_keys(&:to_s)

        @values = {}
        @api = []
        missing = []
        declared.each do |key, spec|
          if given.key?(key)
            add(key, given[key])
          elsif spec.is_a?(Hash) && !spec["Default"].nil?
            @values[key] = text(spec["Default"])
          else
            missing << key
          end
        end
        if missing.any?
          raise ParametersMissing, "The following CloudFormation parameters are missing a value: #{missing.join(", ")}.\n" \
            "Run the command again with --parameters #{missing.map { |key| "#{key}=<value>" }.join(" ")}."
        end

        given.each { |key, value| add(key, value) unless declared.key?(key) || text(value).empty? }
        @resolved_by_cloud_formation = declared.values.any? do |spec|
          spec.is_a?(Hash) && spec["Type"].to_s.start_with?(SSM_TYPE_PREFIX)
        end
      end

      # True when a parameter's value is only known after CloudFormation resolved it.
      def resolved_by_cloud_formation?
        @resolved_by_cloud_formation
      end

      # deployed is { key => value } as the stack was last deployed.
      def changes?(deployed)
        return true if resolved_by_cloud_formation?

        current = deployed || {}
        current.any? { |key, value| !@values.key?(key) || text(value) != @values[key] } ||
          @values.any? { |key, _| !current.key?(key) }
      end

      private

      def add(key, value)
        @values[key] = text(value)
        @api << { parameter_key: key, parameter_value: @values[key] }
      end

      # A list parameter arrives as an Array; CloudFormation takes it as one comma-separated string.
      def text(value)
        value.is_a?(Array) ? value.map { |item| text(item) }.join(",") : value.to_s
      end
    end
  end
end
