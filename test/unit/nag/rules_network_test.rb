# frozen_string_literal: true

require "test_helper"
require "support/nag_case"

# The two ingress rules: RC-EC2-001 and RC-EC2-002, over the inline ingress of
# a security group and over a standalone SecurityGroupIngress.
class NagRulesNetworkTest < Minitest::Test
  include NagCase

  SECURITY_GROUP = "AWS::EC2::SecurityGroup"
  INGRESS = "AWS::EC2::SecurityGroupIngress"
  REASON = "The load balancer terminates TLS for the internet; the instances are reached through it."

  def group_with(*ingress)
    { "GroupDescription" => "g", "SecurityGroupIngress" => ingress }
  end

  def rule(protocol: "tcp", from: 22, to: 22, cidr: "0.0.0.0/0", cidr6: nil)
    { "IpProtocol" => protocol, "FromPort" => from, "ToPort" => to, "CidrIp" => cidr, "CidrIpv6" => cidr6 }.compact
  end

  # --- the shape of the findings

  def test_ingress_finding_says_the_cidr_and_the_ports
    report = check_resource(SECURITY_GROUP, group_with(rule))

    violation = assert_one_violation(report, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP,
      path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "0.0.0.0/0", "tcp ports 22-22", "restrict the source" ])
    assert_equal "RC-EC2-001", violation.rule
  end

  def test_standalone_ingress_is_read_like_an_inline_one
    inline = check_resource(SECURITY_GROUP, group_with(rule(from: 8080, to: 8080)))
    standalone = check_resource(INGRESS, rule(from: 8080, to: 8080))

    assert_one_violation(inline, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "8080" ])
    assert_one_violation(standalone, "RC-EC2-001", severity: :high, resource_type: INGRESS, path: "Properties.CidrIp", says: [ "8080" ])
  end

  def test_the_ingress_written_as_one_object_is_read_as_a_list_of_one
    # CloudFormation lets a list hold one item, written as the item.
    properties = group_with(rule(from: 22, to: 22))
    properties["SecurityGroupIngress"] = rule
    report = check_resource(SECURITY_GROUP, properties)

    assert_one_violation(report, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress.CidrIp", says: [ "22-22" ])
  end

  # --- RC-EC2-001: open to the world, other than the web ports

  def test_other_ports_fails_on_every_way_to_be_open
    ssh = check_resource(SECURITY_GROUP, group_with(rule))
    ipv6 = check_resource(SECURITY_GROUP, group_with(rule(cidr: nil, cidr6: "::/0")))
    all_protocols = check_resource(SECURITY_GROUP, group_with(rule(protocol: -1, from: nil, to: nil)))
    written_as_a_string = check_resource(SECURITY_GROUP, group_with(rule(protocol: "-1", from: "-1", to: "-1")))
    any_protocol_number = check_resource(SECURITY_GROUP, group_with(rule(protocol: 47, from: nil, to: nil)))
    range_covering_other_ports = check_resource(SECURITY_GROUP, group_with(rule(from: 80, to: 8080)))
    expanded_ipv6 = check_resource(SECURITY_GROUP, group_with(rule(cidr: nil, cidr6: "0000:0000:0000:0000:0000:0000:0000:0000/0")))

    assert_one_violation(ssh, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "22-22" ])
    assert_one_violation(ipv6, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP,
      path: "Properties.SecurityGroupIngress[0].CidrIpv6", says: [ "::/0", "22-22" ])
    assert_one_violation(all_protocols, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "every port" ])
    assert_one_violation(written_as_a_string, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "every port" ])
    assert_one_violation(any_protocol_number, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "every port" ])
    assert_one_violation(range_covering_other_ports, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "80-8080" ])
    assert_one_violation(expanded_ipv6, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIpv6", says: [ "22-22" ])
  end

  def test_other_ports_passes_on_a_named_source_and_on_icmp
    named = check_resource(SECURITY_GROUP, group_with(rule(cidr: "10.0.0.0/8")))
    icmp = check_resource(SECURITY_GROUP, group_with(rule(protocol: "icmp", from: 8, to: -1)))
    icmpv6 = check_resource(SECURITY_GROUP, group_with(rule(protocol: "icmpv6", from: nil, to: nil, cidr: nil, cidr6: "::/0")))
    no_ingress = check_resource(SECURITY_GROUP, { "GroupDescription" => "g" })

    assert_findings(named, {})
    assert_findings(icmp, {})
    assert_findings(icmpv6, {})
    assert_findings(no_ingress, {})
  end

  def test_other_ports_does_not_read_an_egress_list
    report = check_resource(SECURITY_GROUP, { "GroupDescription" => "g", "SecurityGroupEgress" => [ rule(from: 1, to: 65_535) ] })

    assert_findings(report, {})
  end

  def test_other_ports_counts_every_dynamic_part_of_one_rule
    dynamic_cidr = check_resource(SECURITY_GROUP, group_with(rule(cidr: { "Ref" => "SshRange" })))
    dynamic_port = check_resource(SECURITY_GROUP, group_with(rule(from: { "Ref" => "Port" })))
    dynamic_protocol = check_resource(SECURITY_GROUP, group_with(rule(protocol: { "Ref" => "Protocol" })))
    dynamic_list = check_resource(SECURITY_GROUP, { "GroupDescription" => "g", "SecurityGroupIngress" => { "Ref" => "Ingress" } })

    assert_undecided(dynamic_cidr, "RC-EC2-001", path: "Properties.SecurityGroupIngress[0].CidrIp")
    assert_undecided(dynamic_port, "RC-EC2-001", path: "Properties.SecurityGroupIngress[0].FromPort")
    assert_undecided(dynamic_protocol, "RC-EC2-001", path: "Properties.SecurityGroupIngress[0].IpProtocol")
    assert_undecided(dynamic_list, "RC-EC2-001", path: "Properties.SecurityGroupIngress")
  end

  def test_other_ports_decides_the_other_rules_when_one_is_left_undecided
    report = check_resource(SECURITY_GROUP, group_with(rule(from: { "Ref" => "Port" }), rule(from: 8080, to: 8080)))

    assert_one_violation(report, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[1].CidrIp", says: [ "8080" ])
    assert_equal [ "Properties.SecurityGroupIngress[0].FromPort" ], undecided(report, "RC-EC2-001")
  end

  def test_other_ports_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(SECURITY_GROUP, group_with(rule), **rules_to_suppress({ "Id" => "RC-EC2-001", "Reason" => REASON }))

    assert_suppressed(report, "RC-EC2-001", reason: REASON)
  end

  # --- RC-EC2-002: open to the world on 80 or 443

  def test_web_ports_fails_on_the_web_ports_and_only_on_them
    http = check_resource(SECURITY_GROUP, group_with(rule(from: 80, to: 80)))
    https = check_resource(SECURITY_GROUP, group_with(rule(from: 443, to: 443)))
    written_as_strings = check_resource(SECURITY_GROUP, group_with(rule(from: "80", to: "80")))
    on_the_standalone = check_resource(INGRESS, rule(from: 443, to: 443))

    assert_one_violation(http, "RC-EC2-002", severity: :medium, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "80-80" ])
    assert_one_violation(https, "RC-EC2-002", severity: :medium, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "443-443" ])
    assert_one_violation(written_as_strings, "RC-EC2-002", severity: :medium, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "80-80" ])
    assert_one_violation(on_the_standalone, "RC-EC2-002", severity: :medium, resource_type: INGRESS, path: "Properties.CidrIp", says: [ "443-443" ])
  end

  def test_web_ports_leaves_every_other_finding_to_the_other_rule
    # A range that holds 80 also holds ports that are not 80 or 443: that is the other rule's finding.
    wide = check_resource(SECURITY_GROUP, group_with(rule(from: 80, to: 8080)))
    web_range = check_resource(SECURITY_GROUP, group_with(rule(from: 80, to: 443)))
    ssh = check_resource(SECURITY_GROUP, group_with(rule))

    assert_findings(wide, { "RC-EC2-001" => [ "Only" ] })
    assert_one_violation(web_range, "RC-EC2-001", severity: :high, resource_type: SECURITY_GROUP, path: "Properties.SecurityGroupIngress[0].CidrIp", says: [ "80-443" ])
    assert_findings(ssh, { "RC-EC2-001" => [ "Only" ] })
  end

  def test_web_ports_passes_on_a_named_source
    report = check_resource(SECURITY_GROUP, group_with(rule(from: 443, to: 443, cidr: "192.168.0.0/16")))

    assert_findings(report, {})
  end

  def test_web_ports_counts_a_dynamic_cidr_or_port
    dynamic_cidr = check_resource(SECURITY_GROUP, group_with(rule(from: 443, to: 443, cidr: { "Ref" => "Range" })))
    dynamic_port = check_resource(SECURITY_GROUP, group_with(rule(from: { "Fn::If" => [ "Tls", 443, 80 ] })))

    assert_undecided(dynamic_cidr, "RC-EC2-002", path: "Properties.SecurityGroupIngress[0].CidrIp")
    assert_undecided(dynamic_port, "RC-EC2-002", path: "Properties.SecurityGroupIngress[0].FromPort")
  end

  def test_web_ports_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(SECURITY_GROUP, group_with(rule(from: 443, to: 443)), **rules_to_suppress({ "Id" => "RC-EC2-002", "Reason" => REASON }))

    assert_suppressed(report, "RC-EC2-002", reason: REASON)
  end

  # --- the two rules together

  def test_one_group_can_report_to_both_rules_and_each_id_suppresses_its_own
    both = check_resource(SECURITY_GROUP, group_with(rule, rule(from: 443, to: 443)))

    assert_findings(both, { "RC-EC2-001" => [ "Only" ], "RC-EC2-002" => [ "Only" ] })

    half = check_resource(SECURITY_GROUP, group_with(rule, rule(from: 443, to: 443)),
      **rules_to_suppress({ "Id" => "RC-EC2-001", "Reason" => REASON }))

    assert_empty violations(half, "RC-EC2-001")
    assert_equal [ "Only" ], hits(half, "RC-EC2-002")
    assert_equal [ REASON ], suppressed(half, "RC-EC2-001").map(&:reason)
  end

  def test_a_port_that_is_a_number_outside_the_protocol_is_undecided_not_a_finding
    report = check_resource(SECURITY_GROUP, group_with(rule(protocol: "sctp", from: 8, to: 8)))

    skipped = assert_undecided(report, "RC-EC2-001", path: "Properties.SecurityGroupIngress[0].IpProtocol")
    assert_includes skipped.reason, "names no protocol"
  end

  def test_an_inverted_port_range_is_undecided
    report = check_resource(SECURITY_GROUP, group_with(rule(from: 100, to: 20)))

    assert_undecided(report, "RC-EC2-001", path: "Properties.SecurityGroupIngress[0]")
    assert_undecided(report, "RC-EC2-002", path: "Properties.SecurityGroupIngress[0]")
  end
end
