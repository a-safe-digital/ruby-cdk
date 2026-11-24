# frozen_string_literal: true

require_relative "rule"
require_relative "scans"
require_relative "template"

module RubyCdk
  module Validation
    module Rules
      # V23: intrinsics in CreationPolicy and UpdatePolicy only where CloudFormation takes
      # them, which is in the place of a string, a number or a boolean, and never in the
      # place of an object.
      #
      # This is what the CDK refuses by default when it reads a template, behind the
      # feature flag cfnIncludeRejectComplexResourceUpdateCreatePolicyIntrinsics
      # (packages/aws-cdk-lib/cx-api/lib/features.ts, recommendedValue true, at
      # aws/aws-cdk@68b2516c): "it uses an intrinsic in a resource update or deletion
      # policy to represent a non-primitive value" (core/lib/helpers-internal/cfn-parse.ts,
      # throwIfIsIntrinsic, over the policy itself and over each of its sections).
      #
      # Architecture §6 says "not in a resource-signal count". The CDK's own tests say
      # otherwise: cloudformation-include/test/test-templates/intrinsics-create-policy-
      # resource-signal.json and intrinsics-create-policy-complex.json are accepted, and
      # hold a Ref and an Fn::If as the count of the signal. What it refuses is an
      # intrinsic where an object belongs, so that is what this rule reports.
      class PolicyIntrinsics < Rule
        rule "V23"

        # The sections of each policy that take an object, by the section they hang under.
        CREATION = { "AutoScalingCreationPolicy" => {}, "ResourceSignal" => {} }.freeze
        UPDATE = {
          "AutoScalingReplacingUpdate" => {},
          "AutoScalingRollingUpdate" => {},
          "AutoScalingScheduledAction" => {},
          "CodeDeployLambdaAliasUpdate" => {},
          "AutoScalingInstanceRefresh" => { "Preferences" => { "AlarmSpecification" => {} } }
        }.freeze

        def call(context)
          issues = []
          Scans::Resources.each(context) do |_name, body, path|
            issues.concat(refused(body["CreationPolicy"], path + [ "CreationPolicy" ], "CreationPolicy", CREATION))
            issues.concat(refused(body["UpdatePolicy"], path + [ "UpdatePolicy" ], "UpdatePolicy", UPDATE))
          end
          issues
        end

        private

        # The intrinsics written in the place of the policy or of one of its sections.
        def refused(object, at, label, sections)
          return [] unless object.is_a?(Hash)

          issues = Template.intrinsic?(object) ? [ not_an_object(at, label) ] : []
          sections.each do |section, deeper|
            next unless object[section].is_a?(Hash)

            issues.concat(refused(object[section], at + [ section ], "#{label}.#{section}", deeper))
          end
          issues
        end

        def not_an_object(at, label)
          error(at, "an intrinsic is written where #{label} takes an object: CloudFormation resolves an intrinsic there only to a string, a number or a boolean",
            hint: "keep the object, and put the intrinsic in one of its leaves, as ResourceSignal: { Count: { Fn::If: [ ... ] } }")
        end
      end
    end
  end
end
