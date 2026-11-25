# frozen_string_literal: true

require "json"
require "yaml"
require_relative "../errors"

module RubyCdk
  module Diff
    # Reads a template from text, and prepares both templates of a diff for the
    # comparison.
    #
    # The deployed template comes back from the port's `get_template` as text:
    # JSON, or YAML when another tool deployed it in that form. A template that
    # is neither is refused, because guessing at how CloudFormation would read
    # it is how a wrong diff gets printed (the deploy engine refuses a YAML
    # template outright, architecture section 9; the diff still works when the
    # text parses as YAML).
    #
    # Normalization never touches the caller's objects: it works on deep copies
    # (the CDK does the same in cloudformation-diff's
    # diffNormalizedTemplates, so that a reordered DependsOn in a template the
    # caller still holds is never seen as a change). What it does is what the
    # CDK's normalize does (lib/diff-template.ts at eca1b73d):
    #
    # - `DependsOn` written as one String becomes a one-element list, and a
    #   list is sorted, so order and shape carry no meaning;
    # - `Fn::GetAtt` written in the short form "LogicalId.Attribute" becomes
    #   the list form, so both spellings compare equal;
    # - symbols become strings, because a Hash built in Ruby has symbol keys
    #   and a template read from JSON does not.
    module Normalizer
      # A template as text, parsed: JSON first, then YAML. Raises
      # RubyCdk::Error with the way out when neither parses. A Hash passes
      # through: the port's get_template answers text, and a test's fake may
      # answer the template as the Hash it registered.
      def self.parse(text)
        return text if text.is_a?(Hash)

        body = JSON.parse(text)
        return body if body.is_a?(Hash)

        raise Error, "the template is a JSON document but not an object, so it cannot be a template"
      rescue JSON::ParserError, TypeError
        begin
          body = YAML.safe_load(text, aliases: true)
        rescue Psych::SyntaxError, Psych::DisallowedClass, ArgumentError
          raise Error, "the template is neither JSON nor YAML a reader of this tool understands: " \
                       "deploy it as JSON, or check what `get_template` answers for the stack"
        end
        return body if body.is_a?(Hash)

        raise Error, "the template parses, but not into an object, so it cannot be a template"
      end

      # A normalized deep copy of the template.
      def self.normalize(template)
        case template
        when Hash then normalize_hash(template)
        when Array then template.map { |item| normalize(item) }
        else template
        end
      end

      # The DependsOn value, as the sorted list the comparison expects.
      def self.depends_on(value)
        list = value.is_a?(Array) ? value : [ value ]
        list.map { |entry| entry.is_a?(String) ? entry : entry.to_s }.sort
      end

      def self.normalize_hash(template)
        template.each_with_object({}) do |(key, value), normalized|
          key = key.to_s unless key.is_a?(String)
          normalized[key] = case key
          when "DependsOn" then depends_on(value)
          when "Fn::GetAtt" then value.is_a?(String) ? value.split(".") : normalize(value)
          else normalize(value)
          end
        end
      end
      private_class_method :normalize_hash
    end
  end
end
