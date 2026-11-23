# frozen_string_literal: true

require_relative "rule"
require_relative "rules/api_gateway_authorization"
require_relative "rules/dynamodb_point_in_time_recovery"
require_relative "rules/ebs_volume_encrypted"
require_relative "rules/ec2_ingress_http"
require_relative "rules/ec2_ingress_other_ports"
require_relative "rules/iam_policy_admin_access"
require_relative "rules/iam_policy_full_access"
require_relative "rules/iam_user_credentials"
require_relative "rules/lambda_runtime_supported"
require_relative "rules/lambda_secret_environment"
require_relative "rules/log_group_retention"
require_relative "rules/rds_storage_encrypted"
require_relative "rules/resource_policy_wildcard_principal"
require_relative "rules/s3_public_access_block"
require_relative "rules/stateful_deletion_policy"

module RubyCdk
  module Nag
    # The rule pack: v0.1, one class per rule.
    module Rules
      # Every rule, in id order. A rule that is not in this list does not run.
      ALL = [
        BucketPublicAccessBlock,
        ResourcePolicyWildcardPrincipal,
        IamPolicyAdminAccess,
        IamPolicyFullAccess,
        IamUserCredentials,
        Ec2IngressOtherPorts,
        Ec2IngressHttp,
        LambdaRuntimeSupported,
        LambdaSecretEnvironment,
        DynamodbPointInTimeRecovery,
        EbsVolumeEncrypted,
        RdsStorageEncrypted,
        ApiGatewayAuthorization,
        StatefulDeletionPolicy,
        LogGroupRetention
      ].freeze

      class << self
        # Every rule id, in ALL's order.
        def ids
          ALL.map(&:id)
        end
      end
    end
  end
end
