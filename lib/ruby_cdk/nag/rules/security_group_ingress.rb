# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # Shared by RC-EC2-001 and RC-EC2-002: finds the ingress rules that a
      # security group resource or an ingress resource declares, and says
      # whether one is open to the world, and on which ports.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0):
      #   - src/rules/ec2/EC2RestrictedInbound.ts, AwsSolutions-EC23 in
      #     src/packs/aws-solutions.ts: a rule is open when its CidrIp or
      #     CidrIpv6 holds "/0", read on the inline ingress list of
      #     AWS::EC2::SecurityGroup and on AWS::EC2::SecurityGroupIngress;
      #   - src/rules/ec2/EC2RestrictedSSH.ts and EC2RestrictedCommonPorts.ts:
      #     how a rule's port range is read.
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: the finding is split by port, as the wave card's two
      # rules ask, where the source reports every open rule under EC23 and
      # reads ports only for SSH and a list of common ports. A protocol other
      # than tcp, udp, icmp and icmpv6 is read as opening every port, which is
      # what the provider schema of AWS::EC2::SecurityGroupIngress says of
      # IpProtocol; the source reads only "-1" that way. ICMP is not a port
      # and raises no finding. A value that is an intrinsic ends the check as
      # skipped, where the source reports an error.
      module SecurityGroupIngress
        INLINE = "Properties.SecurityGroupIngress"
        STANDALONE = "Properties"
        SOURCES = %w[CidrIp CidrIpv6].freeze
        ALL_PROTOCOLS = -1
        ICMP_PROTOCOLS = [ 1, 58 ].freeze
        PROTOCOL_NAMES = { "tcp" => 6, "udp" => 17, "icmp" => 1, "icmpv6" => 58 }.freeze
        ALL_PORTS = :all_ports
        WEB_PORTS = [ 80, 443 ].freeze

        # True when the range holds at least one port other than 80 and 443.
        def self.covers_other_port?(range)
          range.size > WEB_PORTS.length || (range.to_a - WEB_PORTS).any?
        end

        def audit
          if type == "AWS::EC2::SecurityGroupIngress"
            audit_ingress(STANDALONE)
          else
            rules = check(INLINE) { values.item_paths(INLINE) } || []
            rules.each { |path| audit_ingress(path) }
          end
        end

        private

        def audit_ingress(path)
          v = values
          check(path) do
            cidr = SOURCES.find { |key| open_to_the_world?(v.string(full(path, key))) }
            next unless cidr

            protocol = protocol_number(v.raw(full(path, "IpProtocol")), path)
            next if ICMP_PROTOCOLS.include?(protocol)

            ports = protocol == ALL_PROTOCOLS ? ALL_PORTS : port_range(v, path, protocol)
            next if ports.nil?
            next unless flags_ports?(ports)

            violate(full(path, cidr), message(v.string(full(path, cidr)), describe_ports(protocol, ports)))
          end
        end

        # EC23: the source holds "/0", so it is the whole address space.
        def open_to_the_world?(cidr)
          !cidr.nil? && cidr.include?("/0")
        end

        # The number of the protocol: tcp is 6, udp 17, icmp 1, icmpv6 58, and
        # -1 is all of them.
        def protocol_number(written, path)
          name = written.to_s.strip.downcase
          return ALL_PROTOCOLS if name == "-1"
          return PROTOCOL_NAMES.fetch(name) if PROTOCOL_NAMES.key?(name)
          return Integer(name, 10) if /\A\d+\z/.match?(name)

          raise Undecided.new(path, "has IpProtocol #{written.inspect}, which names no protocol")
        end

        # The port range of a tcp or udp rule, or ALL_PORTS when it says -1.
        def port_range(v, path, protocol)
          from_port = v.integer(full(path, "FromPort"))
          to_port = v.integer(full(path, "ToPort"))
          return ALL_PORTS if from_port == -1 || to_port == -1
          if from_port.nil? || to_port.nil?
            raise Undecided.new(path, "is a #{PROTOCOL_NAMES.key(protocol)} rule without a port range, which CloudFormation requires")
          end
          raise Undecided.new(path, "has the inverted port range #{from_port}-#{to_port}") if from_port > to_port

          Range.new(from_port, to_port)
        end

        # "every port", "tcp ports 22-22".
        def describe_ports(protocol, ports)
          return "every port" if ports == ALL_PORTS

          "#{PROTOCOL_NAMES.key(protocol)} ports #{ports.begin}-#{ports.end}"
        end

        def full(path, key)
          [ path, key ].reject(&:empty?).join(".")
        end
      end
    end
  end
end
