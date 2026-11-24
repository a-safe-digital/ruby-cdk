# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # RC-S3-001. A bucket is compliant when all four public access block
      # settings are true.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0):
      #   - src/rules/s3/S3BucketLevelPublicAccessProhibited.ts, AwsSolutions-S2
      #     in src/packs/aws-solutions.ts: BlockPublicAcls, BlockPublicPolicy,
      #     IgnorePublicAcls and RestrictPublicBuckets must all be true.
      #   - src/rules/s3/S3BucketPublicReadProhibited.ts (the compliance packs),
      #     which is non-compliant when PublicAccessBlockConfiguration is absent.
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: a bucket without PublicAccessBlockConfiguration is a
      # violation, as in S3BucketPublicReadProhibited; S2 alone passes it. The
      # ACL half of S3BucketPublicReadProhibited is not ported: the wave card's
      # rule is the four settings. The four settings are each read on their
      # own, so one that is an intrinsic skips only itself.
      class BucketPublicAccessBlock < Rule
        id "RC-S3-001"
        description "S3 bucket has all four public access block settings on"
        severity :high
        applies_to "AWS::S3::Bucket"

        CONFIGURATION = "Properties.PublicAccessBlockConfiguration"
        SETTINGS = %w[BlockPublicAcls IgnorePublicAcls BlockPublicPolicy RestrictPublicBuckets].freeze

        def audit
          v = values
          check(CONFIGURATION) do
            written = v.raw(CONFIGURATION)
            if written.nil?
              violate(CONFIGURATION, "has no PublicAccessBlockConfiguration: set #{SETTINGS.join(", ")} to true")
              next
            end

            off = SETTINGS.filter_map do |setting|
              path = "#{CONFIGURATION}.#{setting}"
              check(path) { v.boolean(path) == true ? nil : setting }
            end
            if off.any?
              violate(CONFIGURATION, "does not block public access: #{off.join(", ")} #{off.one? ? "is" : "are"} not true; set #{off.one? ? "it" : "them"} to true")
            end
          end
        end
      end
    end
  end
end
