# frozen_string_literal: true

require_relative "../rule"
require_relative "policy_statements"

module RubyCdk
  module Nag
    module Rules
      # RC-IAM-001. An IAM policy is compliant when no Allow statement has
      # Action "*" together with a Resource that is "*" or an ARN ending in
      # "*": that statement lets its principal do anything, anywhere.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0),
      # src/rules/iam/IAMPolicyNoStatementsWithAdminAccess.ts, in the
      # HIPAA, NIST 800-53 and PCI DSS packs of src/packs/: "The IAM policy
      # grants admin access, meaning the policy allows a principal to perform
      # all actions on all resources". The source finds the statement with a
      # regular expression over the serialized document: Action holds "*",
      # Effect is "Allow", and Resource holds "*" or an ARN that ends in "*".
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: the statement is read structurally, so the order in
      # which its keys are written does not matter; the regular expression
      # finds only a statement written Action, Effect, Resource in that
      # order. AWS::IAM::User is checked as well: the source leaves users
      # out of this rule, while IAMNoWildcardPermissions, from which it was
      # split, checks them. There is one violation per statement, where the
      # source gives one NON_COMPLIANT per resource.
      class IamPolicyAdminAccess < PolicyStatements
        id "RC-IAM-001"
        description "IAM policy does not grant admin access: no Allow statement with Action \"*\" on Resource \"*\""
        severity :high
        applies_to "AWS::IAM::Policy", "AWS::IAM::ManagedPolicy", "AWS::IAM::Role", "AWS::IAM::User", "AWS::IAM::Group"

        # From the source's regular expression: "*", or an ARN that ends in "*".
        ALL_ACTIONS = "*"
        ALL_RESOURCES = /\A(\*|arn:.*\*)\z/.freeze

        def audit
          each_identity_policy_document do |document|
            each_statement(document) do |path, statement|
              check(path) do
                next unless statement.string("Effect") == "Allow"
                next unless statement.strings("Action").include?(ALL_ACTIONS)

                resources = statement.strings("Resource").grep(ALL_RESOURCES)
                unless resources.empty?
                  violate("#{path}.Resource",
                    "grants admin access: Action \"*\" on #{resources.join(", ")}; name the actions and the resources the principal needs")
                end
              end
            end
          end
        end
      end
    end
  end
end
