# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # RC-RDS-001. A DB instance or an Aurora DB cluster is compliant when
      # its storage is encrypted.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0),
      # src/rules/rds/RDSStorageEncrypted.ts, AwsSolutions-RDS2 in
      # src/packs/aws-solutions.ts: "The RDS instance or Aurora DB cluster
      # does not have storage encryption enabled." For a cluster,
      # non-compliant when StorageEncrypted is absent or false. For an
      # instance, non-compliant when StorageEncrypted is absent or false and
      # its Engine does not hold "aurora": such an instance takes its
      # encryption from its cluster.
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: a second exemption is ported from cfn-nag's F27,
      # RDSDBInstanceStorageEncryptedRule (stelligent/cfn_nag, commit
      # 8b5f03da74202ba323a145e9d037ddce6cab9dec, MIT, Copyright (c)
      # 2016-2021 Stelligent): an instance that names a DBClusterIdentifier is
      # a member of that cluster, which also holds for the members of a Multi-AZ
      # DB cluster, whose engine does not hold "aurora". The cluster itself is
      # still read by this rule. There is one violation per resource, as in the
      # source; its path says where to look.
      class RdsStorageEncrypted < Rule
        id "RC-RDS-001"
        description "RDS DB instance and Aurora DB cluster have storage encryption enabled"
        severity :high
        applies_to "AWS::RDS::DBInstance", "AWS::RDS::DBCluster"

        STORAGE_ENCRYPTED = "Properties.StorageEncrypted"
        ENGINE = "Properties.Engine"
        CLUSTER_IDENTIFIER = "Properties.DBClusterIdentifier"
        AURORA = "aurora"

        def audit
          v = values
          check(STORAGE_ENCRYPTED) do
            next if v.boolean(STORAGE_ENCRYPTED) == true
            next if aurora_engine?(v)
            next if cluster_member?(v)

            violate(STORAGE_ENCRYPTED, "does not encrypt its storage: set StorageEncrypted to true")
          end
        end

        private

        def aurora_engine?(v)
          check(ENGINE) { v.string(ENGINE)&.downcase&.include?(AURORA) }
        end

        def cluster_member?(v)
          check(CLUSTER_IDENTIFIER) { v.present?(CLUSTER_IDENTIFIER) }
        end
      end
    end
  end
end
