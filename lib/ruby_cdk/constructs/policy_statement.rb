# frozen_string_literal: true

require_relative "../errors"

module RubyCdk
  module IAM
    # One statement of an IAM policy: the port of the CDK's PolicyStatement
    # (aws-iam/lib/policy-statement.ts), in the shape the curated constructs
    # need.
    #
    #   RubyCdk::IAM::PolicyStatement.new(
    #     effect: :allow,                              # or :deny
    #     actions: ["s3:GetObject*"],
    #     resources: [bucket.arn, bucket.objects_arn],
    #     principals: "lambda.amazonaws.com",           # a resource policy needs one
    #     conditions: { "Bool" => { "aws:SecureTransport" => "false" } },
    #     sid: "AllowPublishThroughSSLOnly"
    #   )
    #
    # `to_statement` renders the CloudFormation hash, with the CDK's own key
    # order (policy-statement.ts, toStatementJson; the corpus templates carry
    # it): Action, Condition, Effect, Principal, Resource, Sid. A one-element
    # action or resource list is written as the single string, as the CDK
    # writes it ("Action": "sts:AssumeRole"), and so is the whole statement
    # with only the keys it has.
    #
    # A principal renders as the CDK's principals do
    # (aws-iam/lib/principals/*.ts): "*" stays the bare string (AnyPrincipal in
    # a resource policy), a service name - anything with a dot that is not an
    # ARN - becomes { Service: ... }, an ARN or an account id becomes
    # { AWS: ... } exactly as written (the CDK's AccountPrincipal expands a
    # bare account id to the account's root ARN; write the ARN when you mean
    # the account), and a Hash is taken verbatim.
    class PolicyStatement
      # The two effects, as IAM writes them.
      EFFECTS = { allow: "Allow", deny: "Deny" }.freeze

      ARN_PREFIX = "arn:"

      attr_reader :effect, :actions, :resources, :principals, :conditions, :sid

      def initialize(effect: :allow, actions: [], resources: [], principals: nil, conditions: nil, sid: nil)
        @effect = effect_value(effect)
        @actions = Array(actions).map { |action| text(action, "action") }.freeze
        @resources = Array(resources).map { |resource| value(resource, "resource") }.freeze
        @principals = principals.nil? ? nil : list_of(principals).map { |principal| value(principal, "principal") }.freeze
        @conditions = conditions.nil? ? nil : self.class.stringify(conditions, "conditions").freeze
        @sid = sid.nil? ? nil : text(sid, "sid")
      end

      # The statement as the template holds it.
      def to_statement
        {
          "Action" => one_or_list(@actions),
          "Condition" => @conditions,
          "Effect" => @effect,
          "Principal" => principals_fragment,
          "Resource" => one_or_list(@resources),
          "Sid" => @sid
        }.compact
      end

      alias to_h to_statement

      # How a principal value renders inside a statement: the CDK's principal
      # fragments (see the class comment). A list of principals is merged under
      # their keys, as the CDK merges fragments: two ARNs become
      # { "AWS" => [a, b] }.
      def self.principal_fragment(principal)
        case principal
        when "*"
          "*"
        when Hash
          stringify(principal, "principal")
        when String
          string_principal(principal)
        else
          raise UsageError, "a principal is a String, a Hash or \"*\", got #{principal.inspect}"
        end
      end

      class << self
        private

        def string_principal(principal)
          return { "Service" => principal } if principal.include?(".") && !principal.start_with?(ARN_PREFIX)

          { "AWS" => principal }
        end
      end

      # Symbols become strings, recursively, without touching the caller's
      # hash. On the class, because the principal fragments are class-level too.
      def self.stringify(hash, what)
        unless hash.is_a?(Hash)
          raise UsageError, "policy statement #{what} must be a Hash, got #{hash.inspect}"
        end

        hash.to_h do |key, value|
          [ key.to_s, deep_value(value, what) ]
        end
      end

      def self.deep_value(value, what)
        return stringify(value, what) if value.is_a?(Hash)
        return value.name if value.is_a?(Symbol)

        value
      end

      private

      def effect_value(effect)
        return EFFECTS[effect] if EFFECTS.key?(effect)
        return effect if EFFECTS.value?(effect)

        raise UsageError, "effect must be :allow or :deny (or \"Allow\"/\"Deny\"), got #{effect.inspect}"
      end

      def principals_fragment
        return nil if @principals.nil? || @principals.empty?

        merged = {}
        @principals.each do |principal|
          fragment = self.class.principal_fragment(principal)
          return "*" if fragment == "*"

          fragment.each do |key, value|
            merged[key] = merged.key?(key) ? Array(merged[key]).push(value) : value
          end
        end
        merged
      end

      # One value is the value itself, several are the list, none is nothing:
      # how the CDK writes Action and Resource.
      def one_or_list(values)
        return nil if values.empty?

        values.length == 1 ? values.first : values
      end

      def text(value, what)
        return value if value.is_a?(String) && !value.empty?

        raise UsageError, "a policy statement's #{what} must be a non-empty String, got #{value.inspect}"
      end

      # Array() would take a Hash apart: one principal Hash is one principal.
      def list_of(value)
        value.is_a?(Array) ? value : [ value ]
      end

      def value(input, what)
        return input if input.is_a?(String) || input.is_a?(Hash) || input.is_a?(Array)

        raise UsageError, "a policy statement's #{what} must be a String, a Hash or an Array, got #{input.inspect}"
      end
    end
  end
end
