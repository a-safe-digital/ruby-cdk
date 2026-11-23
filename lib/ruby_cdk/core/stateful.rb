# frozen_string_literal: true

module RubyCdk
  module Core
    # The safe defaults of architecture §7 (D-007): the resource types the CDK
    # retains are retained here from the first deploy, per resource type and
    # with no schema needed.
    #
    # The list was read in the CDK's source on 2026-11-23, at commit
    # 78649cb7cf7399204ed63f629964779eeaa8b37a: each of these L2 constructs ends
    # with `applyRemovalPolicy(props.removalPolicy)`, whose default is
    # `RemovalPolicy.RETAIN`; the RDS ones pass `?? RemovalPolicy.SNAPSHOT`.
    module Stateful
      # The two values of `stateful_default:`.
      DEFAULTS = %i[retain_except_on_create delete].freeze

      # Retained by the CDK, and here.
      RETAINED_TYPES = %w[
        AWS::S3::Bucket
        AWS::DynamoDB::Table
        AWS::Logs::LogGroup
        AWS::KMS::Key
        AWS::EC2::Volume
        AWS::ECR::Repository
        AWS::Cognito::UserPool
        AWS::Kinesis::Stream
        AWS::OpenSearchService::Domain
      ].freeze

      # Snapshotted by the CDK, and here.
      SNAPSHOT_TYPES = %w[
        AWS::RDS::DBInstance
        AWS::RDS::DBCluster
      ].freeze

      # What each kind of stateful resource gets, as [DeletionPolicy, UpdateReplacePolicy].
      #
      # With `:delete` the DeletionPolicy is written out rather than left out:
      # CloudFormation's own default for an RDS instance is a snapshot, and the
      # user asked for a teardown that leaves nothing behind.
      RETAIN = %w[ RetainExceptOnCreate Retain ].freeze
      SNAPSHOT = %w[ Snapshot Snapshot ].freeze
      DELETE = [ "Delete", nil ].freeze

      DELETION_POLICIES = {
        delete: "Delete",
        retain: "Retain",
        retain_except_on_create: "RetainExceptOnCreate",
        snapshot: "Snapshot"
      }.freeze

      # CloudFormation accepts no RetainExceptOnCreate for UpdateReplacePolicy (rule V16).
      UPDATE_REPLACE_POLICIES = {
        delete: "Delete",
        retain: "Retain",
        snapshot: "Snapshot"
      }.freeze

      module_function

      # [DeletionPolicy, UpdateReplacePolicy] for a resource type when the user
      # gave neither, or nil for a type that is not stateful.
      def policies_for(type, default:)
        kind = stateful_kind(type)
        return nil unless kind

        if kind == :snapshot && default == :retain_except_on_create
          SNAPSHOT
        elsif default == :delete
          DELETE
        else
          RETAIN
        end
      end

      def stateful?(type)
        !stateful_kind(type).nil?
      end

      # Raises UsageError unless value is one of the two defaults. Returns it as a Symbol.
      def validate_default!(value)
        choice = DEFAULTS.find { |candidate| candidate.to_s == value.to_s }
        unless choice
          raise UsageError, "stateful_default: #{value.inspect} is not one of #{DEFAULTS.map(&:inspect).join(", ")}"
        end

        choice
      end

      # The CloudFormation name of a `deletion_policy:` as the user wrote it
      # (a Symbol or the name itself), nil when absent. Anything else is a UsageError.
      def deletion_policy(value)
        policy(value, DELETION_POLICIES, "deletion_policy")
      end

      # The same for `update_replace_policy:`.
      def update_replace_policy(value)
        policy(value, UPDATE_REPLACE_POLICIES, "update_replace_policy")
      end

      private

      def stateful_kind(type)
        return :retain if RETAINED_TYPES.include?(type)
        return :snapshot if SNAPSHOT_TYPES.include?(type)
      end

      def policy(value, names, keyword)
        return nil if value.nil?

        canonical = names[value] || (names.value?(value) ? value : nil)
        unless canonical
          allowed = names.values.join(", ")
          raise UsageError, "#{keyword}: #{value.inspect} is not one of #{allowed}"
        end

        canonical
      end
    end
  end
end
