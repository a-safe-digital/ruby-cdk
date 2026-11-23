# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # RC-IAM-003. An IAM user is compliant when nothing gives it credentials
      # of its own: no AWS::IAM::AccessKey names it, and it carries no inline
      # policy.
      #
      # The inline policy half is ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0),
      # src/rules/iam/IAMNoInlinePolicy.ts, in the HIPAA, NIST 800-53 and PCI
      # DSS packs of src/packs/: "The IAM Group, User, or Role contains an
      # inline policy", and from cfn-nag (stelligent/cfn_nag, commit
      # 8b5f03da74202ba323a145e9d037ddce6cab9dec, MIT, Copyright (c)
      # 2016-2021 Stelligent), lib/cfn-nag/custom_rules/UserHasInlinePolicyRule.rb,
      # F10: "IAM user should not have any inline policies".
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: the wave card's rule is about users, so the groups and
      # roles of IAMNoInlinePolicy are not ported, nor is its finding on every
      # AWS::IAM::Policy. An empty Policies list is not a finding (the source
      # reports any Policies at all; cfn-nag reports a non-empty one, as here).
      # The access key half is the wave card's own: neither cdk-nag at
      # da5bed77 nor cfn-nag has a rule on AWS::IAM::AccessKey.
      class IamUserCredentials < Rule
        id "RC-IAM-003"
        description "IAM user has no access key and no inline policy"
        severity :medium
        applies_to "AWS::IAM::User", "AWS::IAM::AccessKey"

        INLINE_POLICIES = "Properties.Policies"
        ACCESS_KEY = "AWS::IAM::AccessKey"

        def audit
          if type == ACCESS_KEY
            user = Values.preview(values.peek("Properties.UserName"))
            violate("Properties.UserName", "is an access key, a long-lived credential, for IAM user #{user}: give the workload a role instead")
          else
            audit_inline_policies
          end
        end

        private

        def audit_inline_policies
          check(INLINE_POLICIES) do
            policies = values.item_paths(INLINE_POLICIES)
            next if policies.empty?

            violate(INLINE_POLICIES,
              "has #{policies.length} inline #{policies.one? ? "policy" : "policies"}: attach managed policies to a group the user belongs to instead")
          end
        end
      end
    end
  end
end
