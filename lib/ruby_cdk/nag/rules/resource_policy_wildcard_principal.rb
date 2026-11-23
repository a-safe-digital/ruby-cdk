# frozen_string_literal: true

require_relative "../rule"
require_relative "policy_statements"

module RubyCdk
  module Nag
    module Rules
      # RC-POLICY-001. A resource policy is compliant when no Allow statement
      # grants to a wildcard principal unless a Condition restricts it.
      #
      # Ported from cfn-nag (stelligent/cfn_nag, commit
      # 8b5f03da74202ba323a145e9d037ddce6cab9dec, MIT, Copyright (c)
      # 2016-2021 Stelligent), lib/cfn-nag/custom_rules/:
      #   - S3BucketPolicyWildcardPrincipalRule, F16
      #   - SqsQueuePolicyWildcardPrincipalRule, F21
      #   - SnsTopicPolicyWildcardPrincipalRule, F18
      #   - KMSKeyWildcardPrincipalRule, F76
      # Each reports a resource whose policy holds an Allow statement whose
      # principal is a wildcard, read as cfn-model's Principal.wildcard? reads
      # it (see PolicyStatements).
      #
      # What changed: the wave card adds "without a restricting condition", so
      # a statement that carries a Condition is not reported; cfn-nag reads no
      # condition in these four rules. There is one violation per statement,
      # where cfn-nag gives one per resource. cdk-nag at da5bed77 has no rule
      # of its own for these policies, so none of it is ported here.
      class ResourcePolicyWildcardPrincipal < Rule
        id "RC-POLICY-001"
        description "Resource policy does not grant access to a wildcard principal without a restricting condition"
        severity :high
        applies_to "AWS::S3::BucketPolicy", "AWS::SQS::QueuePolicy", "AWS::SNS::TopicPolicy", "AWS::KMS::Key"

        # Where each resource type writes its policy.
        DOCUMENT = {
          "AWS::S3::BucketPolicy" => "Properties.PolicyDocument",
          "AWS::SQS::QueuePolicy" => "Properties.PolicyDocument",
          "AWS::SNS::TopicPolicy" => "Properties.PolicyDocument",
          "AWS::KMS::Key" => "Properties.KeyPolicy"
        }.freeze

        include PolicyStatements

        def audit
          each_statement(DOCUMENT.fetch(type)) do |path, statement|
            check(path) do
              next unless statement.string("Effect") == "Allow"
              next unless wildcard_principal?(statement.raw("Principal"))
              next if restricts?(statement)

              violate("#{path}.Principal",
                "grants to a wildcard principal (#{Values.preview(statement.peek("Principal"))}) with no restricting condition: " \
                "name the accounts, users or services in Principal, or add a Condition that narrows the grant")
            end
          end
        end
      end
    end
  end
end
