# frozen_string_literal: true

require_relative "../rule"
require_relative "security_group_ingress"

module RubyCdk
  module Nag
    module Rules
      # RC-EC2-001. A security group is compliant when none of its ingress
      # rules is open to the world (0.0.0.0/0 or ::/0) on a port other than
      # 80 and 443, on all ports, or on a protocol that is neither icmp nor
      # icmpv6.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0):
      #   - src/rules/ec2/EC2RestrictedInbound.ts, AwsSolutions-EC23 in
      #     src/packs/aws-solutions.ts: "The Security Group allows for
      #     0.0.0.0/0 or ::/0 inbound access."
      #   - src/rules/ec2/EC2RestrictedSSH.ts, in the HIPAA, NIST 800-53 and
      #     PCI DSS packs: the port test, here for every port but 80 and 443.
      # The reading of the rules is in SecurityGroupIngress, which says what
      # changed there.
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed here: the wave card's severity is high for this half of
      # the findings; the source has ERROR for EC23 and for SSH.
      class Ec2IngressOtherPorts < Rule
        id "RC-EC2-001"
        description "Security group ingress is not open to the world on a port other than 80 or 443"
        severity :high
        applies_to "AWS::EC2::SecurityGroup", "AWS::EC2::SecurityGroupIngress"

        include SecurityGroupIngress

        private

        def flags_ports?(ports)
          ports == SecurityGroupIngress::ALL_PORTS || SecurityGroupIngress.covers_other_port?(ports)
        end

        def message(cidr, ports)
          "allows ingress from #{cidr} on #{ports}: restrict the source to a known CIDR range or a security group"
        end
      end
    end
  end
end
