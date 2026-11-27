# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"

module RubyCdk
  module SecretsManager
    # A reference to an existing secret, by name, without a lookup (D-022):
    # the port of the CDK's fromSecretNameV2 and of the SecretValue behind it
    # (aws-secretsmanager/lib/secret.ts:605-622 and
    # core/lib/secret-value.ts:100-135), read at commit
    # c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   secret = RubyCdk::SecretsManager::Secret.from_name("prod/db")
    #   function(code: ..., handler: ..., environment: { "DB_PASSWORD" => secret.secret_value })
    #   RubyCdk::SecretsManager::Secret.secret_value_from_name("prod/db", json_field: "password")
    #
    # This is not a construct and builds no resource: nothing enters the tree,
    # nothing is looked up, and synthesis calls no AWS. The secret must exist
    # in the account and region the stack deploys to, as the CDK's doc says
    # (secret.ts:597-598). The value is CloudFormation's dynamic reference
    # against the ARN, the string fromSecretNameV2's secretValue resolves
    # (secret.ts:475); the ARN is the CDK's partial ARN of fromSecretNameV2 -
    # "secret" then the name, no generated suffix - built with Fn.sub over
    # CloudFormation's own pseudo parameters, so it works in a stack with no
    # concrete env.
    #
    # A reference-only helper grants nothing by itself: the CDK's grantRead on
    # an imported secret lands on the caller's policy with the caller's own
    # secretsmanager: actions; attach a RubyCdk::IAM::PolicyStatement with
    # secretsmanager:DescribeSecret and secretsmanager:GetSecretValue on the
    # ARN to the role that needs them.
    class Secret
      # The reference, in the CDK's fromSecretNameV2 shape
      # (secret.ts:605-622): a name in, the name, the ARN and the value out.
      def self.from_name(name)
        new(name)
      end

      # The value, in one call. The CDK's SecretValue.secretsManager
      # (secret-value.ts:100-103) with the key its cfnDynamicReferenceKey
      # joins (secret-value.ts:114-135): five parts, the empty ones left
      # empty. version_stage and version_id cannot go together
      # (secret-value.ts:123-125).
      def self.secret_value_from_name(name, json_field: nil, version_stage: nil, version_id: nil)
        new(name).secret_value(json_field: json_field, version_stage: version_stage, version_id: version_id)
      end

      # The partial ARN, in one call: the CDK's fromSecretNameV2 partialArn
      # (secret.ts:612-620), arn:<partition>:secretsmanager:<region>:
      # <account>:secret:<name>.
      def self.arn_from_name(name)
        new(name).arn
      end

      # The reference. The CDK's two refusals of a secret id run here
      # (secret-value.ts:115-121): it must be there, and a name with a colon
      # is an ARN mistake, refused before it becomes an unreadable resolve
      # string.
      def initialize(name)
        raise UsageError, "secretId cannot be empty" if name.nil? || name.empty?
        unless name.start_with?("arn:") || !name.include?(":")
          raise UsageError, "secret id \"#{name}\" is not an ARN but contains \":\""
        end

        @name = name
      end

      attr_reader :name

      # The CDK's partial ARN (secret.ts:612-620). A partial ARN names the
      # secret at deploy whatever suffix Secrets Manager gave it; the doc the
      # CDK quotes (secret.ts:600-603) warns against it in CLI reads, and for
      # policies the CDK writes the ARN with a -?????? suffix in its place.
      def arn
        Fn.sub("arn:${AWS::Partition}:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:${SecretName}",
          "SecretName" => @name)
      end

      # The resolve string, the CDK's SecretValue.secretsManager against the
      # partial ARN, as fromSecretNameV2's secretValue reads it
      # (secret.ts:475): {{resolve:secretsmanager:arn:<partition>:
      # secretsmanager:<region>:<account>:secret:<name>:SecretString:<json
      # field>:<version stage>:<version id>}}, empty parts left empty
      # (secret-value.ts:127-135). An Fn::Sub, so the ARN's pseudo parameters
      # resolve where the value lands. No json_field reads the whole secret
      # JSON. version_stage and version_id cannot go together
      # (secret-value.ts:123-125).
      def secret_value(json_field: nil, version_stage: nil, version_id: nil)
        if version_stage && version_id
          raise UsageError, "versionStage: '#{version_stage}' and versionId: '#{version_id}' were both provided " \
            "but only one is allowed"
        end
        if json_field && !json_field.is_a?(String)
          raise UsageError, "json_field must be a String, got #{json_field.inspect}"
        end

        { "Fn::Sub" =>
          "{{resolve:secretsmanager:arn:${AWS::Partition}:secretsmanager:${AWS::Region}:${AWS::AccountId}:" \
          "secret:#{@name}:SecretString:#{json_field}:#{version_stage}:#{version_id}}}" }
      end
    end
  end
end
