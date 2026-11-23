# frozen_string_literal: true

require_relative "../errors"

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
    #
    # One value sets both attributes, as the CDK's removal policy does
    # (cfn-resource.ts, applyRemovalPolicy): Delete is Delete and Delete,
    # Retain is Retain and Retain, RetainExceptOnCreate is RetainExceptOnCreate
    # and Retain, Snapshot is Snapshot and Snapshot.
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

      # What a deletion policy means for [DeletionPolicy, UpdateReplacePolicy].
      PAIRS = {
        "Delete" => %w[ Delete Delete ],
        "Retain" => %w[ Retain Retain ],
        "RetainExceptOnCreate" => %w[ RetainExceptOnCreate Retain ],
        "Snapshot" => %w[ Snapshot Snapshot ]
      }.freeze

      module_function

      # [DeletionPolicy, UpdateReplacePolicy] for a resource type when the user
      # gave neither, or nil for a type that is not stateful.
      #
      # Under `:delete` both are written out rather than left out, as they are
      # when a CDK construct is told RemovalPolicy.DESTROY: CloudFormation's own
      # default for an RDS instance is a snapshot, and the user asked for a
      # teardown that leaves nothing behind.
      def policies_for(type, default:)
        kind = stateful_kind(type)
        return nil unless kind

        if default == :delete
          PAIRS.fetch("Delete")
        else
          PAIRS.fetch(kind == :snapshot ? "Snapshot" : "RetainExceptOnCreate")
        end
      end

      def stateful?(type)
        !stateful_kind(type).nil?
      end

      # [DeletionPolicy, UpdateReplacePolicy] for a deletion policy the user gave.
      def pair(deletion_policy)
        PAIRS.fetch(deletion_policy)
      end

      # Raises UsageError unless value is one of the two defaults. Returns it as a Symbol.
      def validate_default!(value)
        choice = DEFAULTS.find { |candidate| candidate.to_s == value.to_s }
        unless choice
          Kernel.raise UsageError, "stateful_default: #{value.inspect} is not one of #{DEFAULTS.map(&:inspect).join(", ")}"
        end

        choice
      end

      # The CloudFormation name of a `deletion_policy:` as the user wrote it
      # (a Symbol or the name itself), nil when absent. Anything else is a
      # UsageError, whose message starts with where when it is given.
      def deletion_policy(value, where: nil)
        policy(value, DELETION_POLICIES, "deletion_policy", where)
      end

      # The same for `update_replace_policy:`.
      def update_replace_policy(value, where: nil)
        policy(value, UPDATE_REPLACE_POLICIES, "update_replace_policy", where)
      end

      # :retained or :snapshot for a stateful type, nil for any other.
      def stateful_kind(type)
        if RETAINED_TYPES.include?(type)
          :retained
        elsif SNAPSHOT_TYPES.include?(type)
          :snapshot
        end
      end

      def policy(value, names, keyword, where)
        return nil if value.nil?

        canonical = names[value] || (names.value?(value) ? value : nil)
        unless canonical
          allowed = names.values.join(", ")
          prefix = where ? "#{where}: " : ""
          Kernel.raise UsageError, "#{prefix}#{keyword}: #{value.inspect} is not one of #{allowed}"
        end

        canonical
      end
      private_class_method :stateful_kind, :policy
    end
  end
end
