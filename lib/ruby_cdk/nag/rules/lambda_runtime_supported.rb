# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # RC-LAMBDA-001. A function is compliant when its Runtime is one that
      # Lambda supports, or when its package is a container image, which has
      # no runtime of its own.
      #
      # No rule of cdk-nag (da5bed77c1b08e584e3de2d67534c76871af957f) and none
      # of cfn-nag (8b5f03da74202ba323a145e9d037ddce6cab9dec) covers the
      # runtime, so this rule is this gem's own. It ports the decision the CDK
      # makes when it marks a runtime deprecated, and the list it marks by
      # (aws/aws-cdk, packages/aws-cdk-lib/aws-lambda/lib/runtime.ts, at
      # 78649cb7cf7399204ed63f629964779eeaa8b37a). Every identifier in
      # SUPPORTED_RUNTIMES is a Runtime there that carries no @deprecated.
      # The list was not read from the provider schema: on 2026-11-23 the
      # schema of AWS::Lambda::Function gives Runtime the type string and no
      # enum.
      #
      # What changed: the list is a constant in this file, read on 2026-11-23
      # from the Lambda Developer Guide, "Supported runtimes"
      # (https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html),
      # kept to the four families the wave card names. It is stricter than
      # the CDK's marks by two runtimes: on that day the CDK had not marked
      # nodejs20.x and ruby3.2 deprecated, and the Lambda documentation
      # already did (April 30 and March 31, 2026).
      class LambdaRuntimeSupported < Rule
        id "RC-LAMBDA-001"
        description "Lambda function runs on a supported runtime"
        severity :high
        applies_to "AWS::Lambda::Function"

        # The runtimes Lambda supported on 2026-11-23, newest first in each family.
        SUPPORTED_RUNTIMES = %w[
          ruby4.0 ruby3.4 ruby3.3
          nodejs26.x nodejs24.x nodejs22.x
          python3.15 python3.14 python3.13 python3.12 python3.11 python3.10
          java25 java21 java17.al2023 java11.al2023 java8.al2023 java17 java11 java8.al2
        ].freeze

        # In public preview on 2026-11-23: supported, but not what a finding
        # should tell someone to move to.
        PREVIEW_RUNTIMES = %w[nodejs26.x python3.15].freeze

        # The families the list covers, read from the list itself.
        FAMILIES = SUPPORTED_RUNTIMES.map { |runtime| runtime[/\A[a-z]+/] }.uniq.freeze

        PACKAGE_TYPE = "Properties.PackageType"
        RUNTIME = "Properties.Runtime"

        def audit
          v = values
          package_type = check(PACKAGE_TYPE) { v.string(PACKAGE_TYPE) || "Zip" }
          return if package_type == "Image"

          check(RUNTIME) do
            runtime = v.string(RUNTIME)
            if runtime.nil?
              raise Undecided.new(RUNTIME, "is not set and PackageType is not a literal") if package_type.nil?

              violate(RUNTIME, "has no Runtime: set it to a supported runtime such as #{newest(FAMILIES.first)}")
              next
            end

            family = FAMILIES.find { |candidate| runtime.start_with?(candidate) }
            unless family
              raise Undecided.new(RUNTIME, "is #{runtime.inspect}, of a family this rule does not cover: it keeps #{FAMILIES.join(", ")}")
            end

            unless SUPPORTED_RUNTIMES.include?(runtime)
              violate(RUNTIME, "runs on #{runtime}, which Lambda no longer supports: move it to #{newest(family)}")
            end
          end
        end

        private

        # The newest supported runtime of a family that is not in preview.
        def newest(family)
          SUPPORTED_RUNTIMES.find { |runtime| runtime.start_with?(family) && !PREVIEW_RUNTIMES.include?(runtime) }
        end
      end
    end
  end
end
