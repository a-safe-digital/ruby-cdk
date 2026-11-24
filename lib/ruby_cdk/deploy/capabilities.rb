# frozen_string_literal: true

module RubyCdk
  module Deploy
    # The capabilities a template needs, read from its resources and never from
    # a flag. CloudFormation refuses a change set that lacks one it needs.
    module Capabilities
      IAM = "CAPABILITY_IAM"
      NAMED_IAM = "CAPABILITY_NAMED_IAM"

      # The eight resource types CloudFormation lists as needing a capability.
      IAM_TYPES = %w[
        AWS::IAM::AccessKey
        AWS::IAM::Group
        AWS::IAM::InstanceProfile
        AWS::IAM::ManagedPolicy
        AWS::IAM::Policy
        AWS::IAM::Role
        AWS::IAM::User
        AWS::IAM::UserToGroupAddition
      ].freeze

      # The properties that give an IAM resource an explicit name. A name counts
      # wherever one of them is set on one of the eight types: saying
      # CAPABILITY_NAMED_IAM too often is harmless, and saying it too seldom
      # makes CloudFormation refuse the change set.
      NAME_PROPERTIES = %w[RoleName ManagedPolicyName UserName GroupName InstanceProfileName].freeze

      # template is a parsed template. The answer is empty when none is needed;
      # otherwise CAPABILITY_IAM, and CAPABILITY_NAMED_IAM with it when a name is set.
      def self.for(template)
        resources = template["Resources"]
        iam = (resources.is_a?(Hash) ? resources.values.grep(Hash) : []).select { |resource| IAM_TYPES.include?(resource["Type"]) }
        return [] if iam.empty?

        named = iam.any? do |resource|
          properties = resource["Properties"]
          properties.is_a?(Hash) && NAME_PROPERTIES.any? { |property| !properties[property].nil? }
        end
        named ? [ IAM, NAMED_IAM ] : [ IAM ]
      end
    end
  end
end
