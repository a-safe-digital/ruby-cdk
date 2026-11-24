# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # RC-DYNAMODB-001. A table is compliant when it enables point-in-time
      # recovery.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0),
      # src/rules/dynamodb/DynamoDBPITREnabled.ts, AwsSolutions-DDB3 in
      # src/packs/aws-solutions.ts: "The DynamoDB table does not have
      # Point-in-time Recovery enabled." Non-compliant when
      # PointInTimeRecoverySpecification is absent or its
      # PointInTimeRecoveryEnabled is not true. The same reading is cfn-nag's
      # W78, DynamoDBBackupRule (stelligent/cfn_nag, commit
      # 8b5f03da74202ba323a145e9d037ddce6cab9dec, MIT).
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: the severity is the wave card's, medium, where the
      # source pack has WARN for DDB3.
      class DynamodbPointInTimeRecovery < Rule
        id "RC-DYNAMODB-001"
        description "DynamoDB table has point-in-time recovery enabled"
        severity :medium
        applies_to "AWS::DynamoDB::Table"

        SPECIFICATION = "Properties.PointInTimeRecoverySpecification"
        ENABLED = "#{SPECIFICATION}.PointInTimeRecoveryEnabled"

        def audit
          v = values
          check(SPECIFICATION) do
            next if v.boolean(ENABLED) == true

            violate(SPECIFICATION, "does not enable point-in-time recovery: set PointInTimeRecoverySpecification.PointInTimeRecoveryEnabled to true")
          end
        end
      end
    end
  end
end
