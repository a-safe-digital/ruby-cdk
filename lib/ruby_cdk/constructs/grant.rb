# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "policy_statement"

module RubyCdk
  module Constructs
    # What a grant_* method answers: who was granted what, on which resources.
    #
    # The shape is the minimum a policy statement needs, which is what the
    # CDK's Grant is built from too (aws-iam/lib/grant.ts at
    # c070afb54b9e4dbddd52a85a21077fe970354985): addToPrincipal takes the
    # grantee, the actions and the resource ARNs, makes one Allow statement of
    # them and hands it to the grantee's grantPrincipal. This tool has exactly
    # one kind of principal that can carry a statement, IAM::Role, whose
    # grantPrincipal is the role itself (aws-iam/lib/role.ts:462) and whose
    # addToPrincipalPolicy creates the role's DefaultPolicy resource
    # (role.ts:653); Role#add_to_policy is that method.
    #
    #   grant = bucket.grant_read(role)   # applied: the statement is on the role
    #   grant = bucket.grant_read("arn:aws:iam::123456789012:user/alice")
    #                                     # unapplied: attach it yourself
    #
    # statement renders the statement; to_statement is its CloudFormation hash.
    # applied? says whether it already sits on the principal's policy.
    class Grant
      attr_reader :principal_arn, :actions, :resource_arns

      class << self
        # The port of Grant.addToPrincipal (grant.ts): the statement goes to the
        # principal's own policy when the principal can carry one, and is only
        # returned otherwise. principal is an IAM::Role or an ARN String.
        def add_to_principal(principal, actions, resource_arns)
          grant = new(
            principal_arn: principal_arn_of(principal),
            actions: actions.map(&:dup).freeze,
            resource_arns: Array(resource_arns).map(&:dup).freeze
          )
          return grant.apply_to(principal) if principal.is_a?(IAM::Role)

          grant
        end

        private

        def principal_arn_of(principal)
          return principal.arn if principal.is_a?(IAM::Role)
          return principal if principal.is_a?(String) && !principal.empty?

          raise UsageError, "a grant takes an IAM::Role or a principal ARN String, got #{principal.inspect}"
        end
      end

      def initialize(principal_arn:, actions:, resource_arns:)
        @principal_arn = principal_arn
        @actions = actions
        @resource_arns = resource_arns
        @applied = false
      end

      # Puts the statement on the role's policy. Answers the grant itself, so a
      # caller can carry on with it; calling it twice adds the statement twice.
      def apply_to(role)
        unless role.is_a?(IAM::Role)
          raise UsageError, "apply_to takes an IAM::Role, got #{role.inspect}"
        end

        role.add_to_policy(statement)
        @applied = true
        self
      end

      # The statement of the grant, as the CDK's Grant#statement: Allow, the
      # actions, the resource ARNs, no principal (the role carries its own).
      def statement
        IAM::PolicyStatement.new(actions: @actions, resources: @resource_arns)
      end

      def to_statement
        statement.to_statement
      end

      # True when the statement already sits on the principal's policy.
      def applied?
        @applied
      end
    end
  end
end
