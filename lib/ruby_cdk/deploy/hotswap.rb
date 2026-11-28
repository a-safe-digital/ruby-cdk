# frozen_string_literal: true

require_relative "../errors"
require_relative "../diff"

module RubyCdk
  module Deploy
    # What `deploy --hotswap` may apply directly, and what it may not
    # (architecture section 9). The classification is the CDK's
    # (packages/@aws-cdk/toolkit-lib/lib/api/hotswap/ at f7c9dca95f440a076c2abd61b66b984624b8548e,
    # hotswap-deployments.ts and lambda-functions.ts): the changes of two
    # templates are sorted into the ones a direct update can carry and the
    # ones that need the change set.
    #
    # The CDK sorts changes per resource and applies each hotswappable one
    # with the API of its service (a Lambda function's code and configuration
    # go through the Lambda SDK). This engine applies through one
    # CloudFormation UpdateStack, which carries the whole new template, so the
    # whole diff has to be hotswappable: anything else, and the deploy falls
    # back -- there is no partial hotswap here, because an UpdateStack whose
    # template leaves resources out deletes them.
    #
    # Every line the engine prints around this is the CDK's own wording, read
    # at the commit above (hotswap-deployments.ts, deploy-stack.ts,
    # cdk-toolkit.ts).
    module Hotswap
      # The resource type the fast path updates. The CDK's detectors also
      # carry AppSync, ECS, CodeBuild, Step Functions, ECR images and the
      # CloudControl types; none of them is a construct of this tool, so a
      # change to any other type is refused.
      LAMBDA_FUNCTION = "AWS::Lambda::Function"

      # The CDK's two HotswapMode words (hotswap/common.ts): --hotswap-fallback
      # hands the deploy to the change set when anything is refused, --hotswap
      # ignores what it cannot apply.
      FALL_BACK = "fall-back"
      HOTSWAP_ONLY = "hotswap-only"

      # The function properties the fast path carries: the code (an asset's
      # S3 location, or inline code) and the configuration CloudFormation
      # updates in place. The CDK's detector classifies only Code,
      # Environment and Description, because it applies them with the Lambda
      # API; the difference is recorded in architecture section 21.
      HOTSWAPPABLE_PROPERTIES = %w[Code Handler Runtime MemorySize Timeout Environment Description].freeze

      # The code properties that name an image in a registry. The CDK's ECR
      # image swap is a detector this tool does not carry: an image-based
      # function falls back.
      IMAGE_CODE = "ImageUri"

      # The two lines above every hotswap deploy (cdk-toolkit.ts, printed once
      # per command, as here).
      WARNINGS = [
        "⚠️ The --hotswap and --hotswap-fallback flags deliberately introduce CloudFormation drift to speed up deployments",
        "⚠️ They should only be used for development - never use them for your production Stacks!"
      ].freeze

      # One function the fast path updates. name is the physical function
      # name when the template writes it as a plain string, and nil when a
      # CloudFormation expression stands in its place.
      SwappedFunction = Struct.new(:logical_id, :resource_type, :name, keyword_init: true)

      # One change the fast path cannot carry, with the CDK's reason.
      RejectedChange = Struct.new(:logical_id, :resource_type, :reason, keyword_init: true)

      # The classification of one template diff. What the diff found outside
      # the resources -- a changed output, a changed parameter, a changed
      # template attribute -- is here too, as rejected changes: an
      # UpdateStack carries them, so they block the fast path rather than
      # being applied unannounced.
      Plan = Struct.new(:swapped, :rejected, keyword_init: true) do
        def hotswappable?
          rejected.empty?
        end
      end

      module_function

      # The classification of a TemplateDiff. The order is the diff's own:
      # removals, additions, updates. A resource whose definition changed
      # outside its Properties (DeletionPolicy, Metadata) does not block, as
      # the CDK's detector ignores its otherDiffs. A change anywhere else in
      # the template does block: the fast path's one UpdateStack would carry
      # it, where the CDK's per-resource calls would leave it out -- every
      # such entry is reported as a rejected change, the outputs with the
      # CDK's own reason, the rest with one of this tool's.
      def plan(diff)
        swapped = []
        rejected = []

        if [ diff.format_version, diff.description, diff.transform ].compact.any?
          rejected << RejectedChange.new(logical_id: diff.stack_name, resource_type: "Template",
            reason: "the template's own attributes changed (AWSTemplateFormatVersion, Description or Transform)")
        end
        diff.sections.each do |section, entries|
          entries.each_key do |name|
            if section == "Outputs"
              rejected << RejectedChange.new(logical_id: name, resource_type: "Output", reason: "output was changed")
            else
              rejected << RejectedChange.new(logical_id: name, resource_type: section,
                reason: "template section '#{section}' changed outside the resources")
            end
          end
        end
        diff.unknown.each_key do |key|
          rejected << RejectedChange.new(logical_id: key, resource_type: "Template",
            reason: "template key '#{key}' changed outside the resources")
        end

        diff.changes.each do |change|
          type = change.new_type || change.old_type
          if change.removal?
            rejected << RejectedChange.new(logical_id: change.logical_id, resource_type: change.old_type,
              reason: "resource '#{change.logical_id}' was destroyed by this deployment")
          elsif change.addition?
            rejected << RejectedChange.new(logical_id: change.logical_id, resource_type: change.new_type,
              reason: "resource '#{change.logical_id}' was created by this deployment")
          elsif change.type_changed?
            rejected << RejectedChange.new(logical_id: change.logical_id, resource_type: change.new_type,
              reason: "resource '#{change.logical_id}' had its type changed from '#{change.old_type}' to '#{change.new_type}'")
          elsif type != LAMBDA_FUNCTION
            rejected << RejectedChange.new(logical_id: change.logical_id, resource_type: type,
              reason: "This resource type is not supported for hotswap deployments")
          else
            classify_function(change, swapped, rejected)
          end
        end

        Plan.new(swapped: swapped, rejected: rejected)
      end

      # One AWS::Lambda::Function that exists on both sides, of the same type:
      # hotswappable when every changed property is one the fast path carries,
      # and the code is not an image. The reason for a refused property list is
      # the CDK's, its property names as Ruby writes them.
      def classify_function(change, swapped, rejected)
        names = change.properties.map(&:name)
        refused = names - HOTSWAPPABLE_PROPERTIES
        unless refused.empty?
          rejected << RejectedChange.new(logical_id: change.logical_id, resource_type: LAMBDA_FUNCTION,
            reason: "resource properties '#{refused.inspect}' are not hotswappable on this resource type")
          return
        end

        code = new_properties(change)["Code"]
        if code.is_a?(Hash) && code.key?(IMAGE_CODE)
          rejected << RejectedChange.new(logical_id: change.logical_id, resource_type: LAMBDA_FUNCTION,
            reason: "the function's code is an ECR image, which this tool does not hotswap")
          return
        end

        swapped << SwappedFunction.new(logical_id: change.logical_id, resource_type: LAMBDA_FUNCTION,
          name: function_name(change))
      end

      # What the fast path prints for one function: the CDK's resourceText --
      # the physical name when there is one, the logical ID when there is not.
      def resource_text(function)
        "#{function.resource_type} '#{function.name || function.logical_id}'"
      end

      def new_properties(change)
        value = change.new_value
        value.is_a?(Hash) && value["Properties"].is_a?(Hash) ? value["Properties"] : {}
      end

      def function_name(change)
        name = new_properties(change)["FunctionName"]
        name.is_a?(String) ? name : nil
      end

      private_class_method :new_properties, :function_name
    end
  end
end
