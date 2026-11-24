# frozen_string_literal: true

require_relative "../rule"
require_relative "policy_statements"

module RubyCdk
  module Nag
    module Rules
      # RC-IAM-002. An IAM policy is compliant when no Allow statement has an
      # Action that is "*", or a service with ":*" after it such as "s3:*":
      # the statement lets its principal do everything to what it names.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0),
      # src/rules/iam/IAMPolicyNoStatementsWithFullAccess.ts, in the HIPAA,
      # NIST 800-53 and PCI DSS packs of src/packs/: "The IAM policy grants
      # full access, meaning the policy allows a principal to perform all
      # actions on individual resources". The source finds the statement with
      # a regular expression over the serialized document: an Action that is
      # "*" or "word:*", then Effect "Allow".
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: the statement is read structurally, so the order in
      # which its keys are written does not matter. AWS::IAM::User is checked
      # as well, as in RC-IAM-001. There is one violation per statement, where
      # the source gives one NON_COMPLIANT per resource. A statement with
      # Action "*" and Resource "*" is reported here and by RC-IAM-001.
      class IamPolicyFullAccess < PolicyStatements
        id "RC-IAM-002"
        description "IAM policy does not grant full access: no Allow statement with Action \"*\""
        severity :medium
        applies_to "AWS::IAM::Policy", "AWS::IAM::ManagedPolicy", "AWS::IAM::Role", "AWS::IAM::User", "AWS::IAM::Group"

        # From the source's regular expression: "*", or a word and ":*".
        FULL_ACCESS_ACTION = /\A(\*|\w+:\*)\z/.freeze

        def audit
          each_identity_policy_document do |document|
            each_statement(document) do |path, statement|
              check(path) do
                next unless statement.string("Effect") == "Allow"

                actions = statement.strings("Action").grep(FULL_ACCESS_ACTION)
                unless actions.empty?
                  violate("#{path}.Action", "grants full access: Action #{actions.join(", ")}; name the actions the principal needs")
                end
              end
            end
          end
        end
      end
    end
  end
end
