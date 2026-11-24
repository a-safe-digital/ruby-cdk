# frozen_string_literal: true

require_relative "../rule"
require_relative "security_group_ingress"

module RubyCdk
  module Nag
    module Rules
      # RC-EC2-002. A security group is compliant when none of its ingress
      # rules is open to the world (0.0.0.0/0 or ::/0) on port 80 or 443: a
      # range that holds only 80, only 443, or both. A range that holds any
      # other port is RC-EC2-001's finding, not this one's.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0):
      #   - src/rules/ec2/EC2RestrictedInbound.ts, AwsSolutions-EC23 in
      #     src/packs/aws-solutions.ts: "The Security Group allows for
      #     0.0.0.0/0 or ::/0 inbound access." Its explanation names the two
      #     ports: "your web servers may only require 80 and 443 ports to be
      #     open, but not all".
      #   - src/rules/ec2/EC2RestrictedSSH.ts: the port test.
      # The reading of the rules is in SecurityGroupIngress, which says what
      # changed there.
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed here: the wave card gives the web ports their own rule,
      # at medium, where the source reports them under EC23 at ERROR.
      class Ec2IngressHttp < SecurityGroupRule
        id "RC-EC2-002"
        description "Security group ingress is not open to the world on port 80 or 443"
        severity :medium
        applies_to "AWS::EC2::SecurityGroup", "AWS::EC2::SecurityGroupIngress"

        private

        def flags_ports?(ports)
          ports != SecurityGroupRule::ALL_PORTS && !SecurityGroupRule.covers_other_port?(ports)
        end

        def message(cidr, ports)
          "allows ingress from #{cidr} on #{ports}: the web ports are open to everyone; " \
          "put a load balancer or a CloudFront distribution in front, or restrict the source"
        end
      end
    end
  end
end
