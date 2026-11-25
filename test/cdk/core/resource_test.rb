# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/core/test/resource.test.ts, in aws/aws-cdk
#   Commit:  622f51fa4999d5557c1d1da292c04cc186ac6818 (main, read on 2026-11-24)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 38 cases, all plain `test(`. Each ported one keeps its name,
# as a comment above the test, and what it expects. What changed to get there:
#
#   - The origin's `new Stack()` is `stack` here: a Stack of this tool needs an
#     App and an id (CdkCore::TestCase#stack).
#   - `res.getAtt(name)` and `res.ref` are Fn.get_att(res, name) and Fn.ref(res),
#     the module functions of architecture §3. A subclass that wants attribute
#     properties defines readers over them, as the origin's Counter does.
#   - `r2.node.addDependency(r1)` is the depends_on: keyword of
#     Construct#resource: the dependency is declared when the resource is,
#     not added to it afterwards.
#   - Every template below carries AWSTemplateFormatVersion 2010-09-09, which
#     the serialization contract writes here always and the CDK writes only
#     when templateOptions names one. with_format_version marks it on every
#     expectation the key adds to.
#
# Changed expectations, stated next to the test:
#
#   - all entities have a logical ID calculated based on their full path in the
#     tree. The CDK's logical ID is the path with an 8-character hash behind
#     it, which its test strips (withoutHash). Here the concatenation of the
#     ids above the resource is the whole logical ID, never hashed (D-004,
#     D-029), so the port asserts it without stripping anything.
#   - removal policy is a high level abstraction of deletion policy used by l2.
#     The CDK's applyRemovalPolicy defaults to Retain when it is called with
#     nothing (cfn-resource.ts:143), so its Default2 carries Retain on both
#     policies. Here a policy is written only when one is given, and the
#     defaults that exist are per type (D-007, architecture §7): T4 is not a
#     stateful type, so its Default2 carries nothing.
#
# FINDING, ported and left failing:
#
#   - if addDependency is called multiple times with the same resource, it will
#     only appear once. The CDK keeps dependencies in a Set
#     (cfn-resource.ts:91, .add at :500) and its test expects DependsOn
#     ["Counter1"] after five adds. Here depends_on: keeps every entry it is
#     given, and the template holds the same logical ID five times.
#
# Not ported, with the reason:
#
#   Not ported because a later wave builds it:
#   - creation/update/updateReplace/deletion policies can be set on a resource;
#     update policies UseOnlineResharding flag; enableVersionUpgrade can be set
#     on a resource. The L1 cannot declare CreationPolicy or UpdatePolicy: the
#     signature of architecture §3 names neither keyword. The validator reads
#     them in parsed templates (rules V20–V23), and Wave 2, the schema-backed
#     L1, is where the declaration would join the contract.
#   - applyRemovalPolicy available for interface resources. It needs the L2
#     base construct and its removal-policy plumbing: Wave 7.
#   - addDependency adds all dependencyElements of dependent constructs. It
#     takes a dependency on a construct and flattens it to the resources
#     inside: automatic dependencies, Wave 4 (W4.6, inferred dependencies).
#   - the describe('overrides') block, 17 cases: addOverride(p, v) allows
#     assigning arbitrary values to synthesized resource definitions;
#     addPropertyOverride() allows assigning an attribute of a different
#     resource; addOverride(p, null) will assign an "null" value;
#     addOverride(p, undefined) can be used to delete a value;
#     addOverride(p, undefined) will not create empty trees;
#     addDeletionOverride(p) and addPropertyDeletionOverride(pp) are sugar for
#     `undefined`; addOverride(p, v) will overwrite any non-objects along the
#     path; addOverride(p, v) will not split on escaped dots;
#     addPropertyOverride(pp, v) is a sugar for overriding properties;
#     overrides are applied after render; overrides allow overriding one
#     intrinsic with another; Can override a an object with an intrinsic;
#     overrides allow overriding a nested intrinsic; overrides allow
#     cross-stack references; and the three of describe('using mutable
#     properties'). The override machinery is not built by any wave before
#     0.1.0, and the cross-stack one would also need what architecture §9
#     refuses to generate.
#
#   Not ported because this tool differs by design:
#   - "aws:cdk:path" metadata is added if "aws:cdk:path-metadata" context is
#     set to true. There is no context system and no path metadata here
#     (architecture §3).
#   - cross-stack construct dependencies are not rendered but turned into stack
#     dependencies. It turns on the CDK's automatic cross-stack reference,
#     which this tool does not generate (architecture §9; D-003).
#   - Resource can get account and Region from ARN. There is no
#     environmentFromArn: a stack's env is an Env or the app's (architecture
#     §3), and a resource carries none of its own.
#
# Every id these cases declare is letters and digits: the rule that refuses
# any other logical ID where an element is declared (in the tree since 796deb2)
# moves no expectation here.
#
# Parity: 38 cases in the origin; 13 ported; 25 not ported.

require "test_helper"
require "support/cdk_core"

class CdkCoreResourceTest < CdkCore::TestCase
  # describe('resource')

  # test('all resources derive from Resource, which derives from Entity')
  def test_all_resources_derive_from_resource_which_derives_from_entity
    stack = stack { resource("MyResource", "MyResourceType", properties: { "Prop1" => "p1", "Prop2" => 123 }) }

    assert_equal(with_format_version(
      "Resources" => {
        "MyResource" => {
          "Type" => "MyResourceType",
          "Properties" => { "Prop1" => "p1", "Prop2" => 123 }
        }
      }
    ), stack.to_template)
  end

  # test('resources must reside within a Stack and fail upon creation if not')
  def test_resources_must_reside_within_a_stack_and_fail_upon_creation_if_not
    app = build_app

    error = assert_raises(RubyCdk::UsageError) { app.resource("R1", "ResourceType") }

    assert_match(/has no Stack above it/, error.message)
  end

  # test('all entities have a logical ID calculated based on their full path in the tree')
  # Changed: the CDK's logical ID is the path with an 8-character hash behind
  # it, which its own test strips (withoutHash). Here the ids above the
  # resource, joined, are the whole logical ID (D-004, D-029): nothing to strip.
  def test_all_entities_have_a_logical_id_calculated_based_on_their_full_path_in_the_tree
    stack = stack do
      level1 = RubyCdk::Construct.new(self, "level1")
      level2 = RubyCdk::Construct.new(level1, "level2")
      level3 = RubyCdk::Construct.new(level2, "level3")
      @res1 = level1.resource("childoflevel1", "MyResourceType1")
      @res2 = level3.resource("childoflevel3", "MyResourceType2")
    end

    assert_equal "level1childoflevel1", stack.instance_variable_get(:@res1).logical_id
    assert_equal "level1level2level3childoflevel3", stack.instance_variable_get(:@res2).logical_id
  end

  # test('resource.props can only be accessed by derived classes')
  def test_resource_props_can_only_be_accessed_by_derived_classes
    counter = Class.new(RubyCdk::Cfn::Resource) do
      attr_accessor :count

      # The CDK re-reads cfnProperties when the template is made; a Lazy
      # defers the read the same way here.
      def initialize(scope, id, count:)
        @count = count
        super(scope, id, type: "My::Counter", properties: { "Count" => Lazy.new { @count } })
      end

      def increment(by = 1)
        @count += by
      end
    end

    stack = stack do
      @res = counter.new(self, "MyResource", count: 10)
      @res.increment
      @res.increment(2)
    end

    assert_equal(with_format_version(
      "Resources" => { "MyResource" => { "Type" => "My::Counter", "Properties" => { "Count" => 13 } } }
    ), stack.to_template)
  end

  # test('resource attributes can be retrieved using getAtt(s) or attribute properties')
  def test_resource_attributes_can_be_retrieved_using_get_att_s_or_attribute_properties
    counter = Class.new(RubyCdk::Cfn::Resource) do
      def arn
        Fn.get_att(self, "Arn")
      end

      def url
        Fn.get_att(self, "URL")
      end
    end

    stack = stack do
      @res = counter.new(self, "MyResource", type: "My::Counter", properties: { "Count" => 10 })
      resource("YourResource", "Type", properties: {
        "CounterName" => Fn.get_att(@res, "Name"),
        "CounterArn" => @res.arn,
        "CounterURL" => @res.url
      })
    end

    assert_equal(with_format_version(
      "Resources" => {
        "MyResource" => { "Type" => "My::Counter", "Properties" => { "Count" => 10 } },
        "YourResource" => {
          "Type" => "Type",
          "Properties" => {
            "CounterName" => { "Fn::GetAtt" => [ "MyResource", "Name" ] },
            "CounterArn" => { "Fn::GetAtt" => [ "MyResource", "Arn" ] },
            "CounterURL" => { "Fn::GetAtt" => [ "MyResource", "URL" ] }
          }
        }
      }
    ), stack.to_template)
  end

  # test('ARN-type resource attributes have some common functionality')
  def test_arn_type_resource_attributes_have_some_common_functionality
    counter = Class.new(RubyCdk::Cfn::Resource) do
      def arn
        Fn.get_att(self, "Arn")
      end
    end

    stack = stack do
      @res = counter.new(self, "MyResource", type: "My::Counter", properties: { "Count" => 1 })
      resource("MyResource2", "Type", properties: { "Perm" => @res.arn })
    end

    assert_equal(with_format_version(
      "Resources" => {
        "MyResource" => { "Type" => "My::Counter", "Properties" => { "Count" => 1 } },
        "MyResource2" => {
          "Type" => "Type",
          "Properties" => { "Perm" => { "Fn::GetAtt" => [ "MyResource", "Arn" ] } }
        }
      }
    ), stack.to_template)
  end

  # test('resource.addDependency(e) can be used to add a DependsOn on another resource')
  # Changed: the dependency is declared with depends_on: when the resource is,
  # where the CDK calls node.addDependency after the fact. The template is the
  # CDK's.
  def test_resource_add_dependency_e_can_be_used_to_add_a_depends_on_on_another_resource
    stack = stack do
      @r1 = resource("Counter1", "My::Counter", properties: { "Count" => 1 })
      @r3 = resource("Resource3", "MyResourceType")
      resource("Counter2", "My::Counter", properties: { "Count" => 1 }, depends_on: [ @r1, @r3 ])
    end

    template = stack.to_template

    assert_equal(with_format_version(
      "Resources" => {
        "Counter1" => { "Type" => "My::Counter", "Properties" => { "Count" => 1 } },
        "Counter2" => {
          "Type" => "My::Counter",
          "Properties" => { "Count" => 1 },
          "DependsOn" => [ "Counter1", "Resource3" ]
        },
        "Resource3" => { "Type" => "MyResourceType" }
      }
    ), template)
  end

  # FINDING: the CDK renders a dependency once however often it is added. Its
  # dependencies live in a Set (core/lib/cfn-resource.ts:91, .add at :500) and
  # its own test expects DependsOn ["Counter1"] for five adds
  # (resource.test.ts, 'if addDependency is called multiple times with the same
  # resource, it will only appear once'). Here depends_on: keeps every entry it
  # is given, and the template holds ["Counter1", "Counter1", "Counter1",
  # "Counter1", "Counter1"]. Expected DependsOn to hold Counter1 once.
  # test('if addDependency is called multiple times with the same resource, it will only appear once')
  def test_if_add_dependency_is_called_multiple_times_with_the_same_resource_it_will_only_appear_once
    stack = stack do
      @r1 = resource("Counter1", "My::Counter", properties: { "Count" => 1 })
      resource("Dependent", "R", depends_on: [ @r1, @r1, @r1, @r1, @r1 ])
    end

    assert_equal [ "Counter1" ], stack.to_template["Resources"]["Dependent"]["DependsOn"]
  end

  # test('conditions can be attached to a resource')
  def test_conditions_can_be_attached_to_a_resource
    stack = stack do
      condition("MyCondition", Fn.not_(Fn.equals("a", "b")))
      resource("Resource", "Type", condition: "MyCondition")
    end

    assert_equal(with_format_version(
      "Conditions" => { "MyCondition" => { "Fn::Not" => [ { "Fn::Equals" => [ "a", "b" ] } ] } },
      "Resources" => { "Resource" => { "Type" => "Type", "Condition" => "MyCondition" } }
    ), stack.to_template)
  end

  # test('metadata can be set on a resource')
  def test_metadata_can_be_set_on_a_resource
    stack = stack { resource("Resource", "Type", metadata: { "MyKey" => 10, "MyValue" => 99 }) }

    assert_equal(with_format_version(
      "Resources" => {
        "Resource" => { "Type" => "Type", "Metadata" => { "MyKey" => 10, "MyValue" => 99 } }
      }
    ), stack.to_template)
  end

  # test('the "type" property is required when creating a resource')
  def test_the_type_property_is_required_when_creating_a_resource
    plain = stack

    error = assert_raises(RubyCdk::UsageError) { plain.resource("Resource", nil) }

    assert_match(/the resource type must be a name/, error.message)
  end

  # test('removal policy is a high level abstraction of deletion policy used by l2')
  # Changed: the CDK's applyRemovalPolicy defaults to Retain when it is called
  # with nothing (core/lib/cfn-resource.ts:143), so its Default2 carries
  # Retain on both policies. Here a policy is written only when one is given,
  # and the defaults that exist are per type (D-007, architecture §7): T4 is
  # not a stateful type, so Default2 carries nothing.
  def test_removal_policy_is_a_high_level_abstraction_of_deletion_policy_used_by_l2
    stack = stack do
      resource("Retain", "T1", deletion_policy: :retain)
      resource("Destroy", "T3", deletion_policy: :delete)
      resource("Default1", "T4", deletion_policy: :delete)
      resource("Default2", "T4")
    end

    assert_equal(with_format_version(
      "Resources" => {
        "Retain" => { "Type" => "T1", "DeletionPolicy" => "Retain", "UpdateReplacePolicy" => "Retain" },
        "Destroy" => { "Type" => "T3", "DeletionPolicy" => "Delete", "UpdateReplacePolicy" => "Delete" },
        "Default1" => { "Type" => "T4", "DeletionPolicy" => "Delete", "UpdateReplacePolicy" => "Delete" },
        "Default2" => { "Type" => "T4" }
      }
    ), stack.to_template)
  end

  # test('resource.ref returns the {Ref} token')
  def test_resource_ref_returns_the_ref_token
    stack = stack { @r = resource("MyResource", "R") }

    assert_equal({ "Ref" => "MyResource" }, stack.resolve(Fn.ref(stack.instance_variable_get(:@r))))
  end
end
