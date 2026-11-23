# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # RC-EBS-001. A volume is compliant when it is encrypted.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0),
      # src/rules/ec2/EC2EBSVolumeEncrypted.ts, AwsSolutions-EC26 in
      # src/packs/aws-solutions.ts: "The resource creates one or more EBS
      # volumes that have encryption disabled." For a CfnVolume, non-compliant
      # when Encrypted is not true. The same reading is cfn-nag's F1,
      # EbsVolumeHasSseRule (stelligent/cfn_nag, commit
      # 8b5f03da74202ba323a145e9d037ddce6cab9dec, MIT).
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: only the volume resource is ported, which is the wave
      # card's rule. The source also reads the block device mappings of an
      # instance, of a launch configuration, of a launch template and of an
      # auto scaling group; those are not ported.
      class EbsVolumeEncrypted < Rule
        id "RC-EBS-001"
        description "EBS volume is encrypted"
        severity :high
        applies_to "AWS::EC2::Volume"

        ENCRYPTED = "Properties.Encrypted"

        def audit
          check(ENCRYPTED) do
            violate(ENCRYPTED, "is not encrypted: set Encrypted to true") unless values.boolean(ENCRYPTED) == true
          end
        end
      end
    end
  end
end
