# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # RC-LOGS-001. A log group is compliant when it sets a retention period.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0),
      # src/rules/cloudwatch/CloudWatchLogGroupRetentionPeriod.ts, in the
      # Serverless pack and in the HIPAA, NIST 800-53 and PCI DSS packs of
      # src/packs/: "The CloudWatch Log Group does not have an explicit
      # retention policy defined. By default, logs are kept indefinitely and
      # never expire." Non-compliant when RetentionInDays is undefined. The
      # same reading is cfn-nag's W86, LogsLogGroupRetentionRule
      # (stelligent/cfn_nag, commit 8b5f03da74202ba323a145e9d037ddce6cab9dec, MIT).
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: the severity is the wave card's, low, where the source
      # packs have WARN or ERROR.
      class LogGroupRetention < Rule
        id "RC-LOGS-001"
        description "CloudWatch log group has a retention period"
        severity :low
        applies_to "AWS::Logs::LogGroup"

        RETENTION_IN_DAYS = "Properties.RetentionInDays"

        def audit
          check(RETENTION_IN_DAYS) do
            violate(RETENTION_IN_DAYS, "keeps its logs forever: set RetentionInDays, for example to 30 or 90") unless values.present?(RETENTION_IN_DAYS)
          end
        end
      end
    end
  end
end
