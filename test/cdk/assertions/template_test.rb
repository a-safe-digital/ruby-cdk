# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/test/template.test.ts
#           (the code it tests: packages/aws-cdk-lib/assertions/lib/template.ts and lib/private/*)
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#
#   Cases: 85 in the original. 82 ported and passing, 3 not ported, 0 failing.
#
#   Not ported, because they need what this tool does not have (a Stage, an App
#   or a NestedStack: here a template comes from to_template, a Hash or a JSON
#   string):
#   - fromStack > nested: a NestedStack inside the stack. Template.fromStack reads
#     the nested template from the synthesized assembly.
#   - fromStack > fails when root is not a stage: a stack whose parent is a bare
#     Construct. It tests Stage.of(stack) inside toTemplate().
#   - nested stack inside a Stage in an App: a NestedStack in a Stage in an App.
#
#   Changed, with nothing else in a scenario, an input or an outcome:
#   - Template.fromStack(stack) is T.template(hash), T being RubyCdk::Test, with
#     the same template the stack synthesizes to, written as a Hash: the resource
#     as `new CfnResource(stack, id, { type, properties })` writes it, the output
#     as CfnOutput does, and so on. In these stacks every resource sits directly
#     in the stack, so the logical ID is the construct's id and nothing was hashed:
#     no expectation needed changing for logical IDs or for a retention policy,
#     since none of these stacks has one.
#   - A stack built with `new Stack()` also carries the parameter BootstrapVersion
#     and the rule CheckBootstrapVersion that the CDK's default synthesizer adds.
#     They are left out of the Hashes. The outcome of no case depends on them but
#     one, hasParameter > not matching, whose message counts them: there the
#     parameter is written by hand, so that the count is the same, 3, as there.
#     The description of that parameter is read from the synthesizer's source
#     except its last marker, "[cdk:skip]", the value of cxapi.SSMPARAM_NO_INVALIDATE,
#     which I could not locate at this commit.
#   - templateMatches > matches used an App and a LegacyStackSynthesizer: what it
#     synthesizes is exactly the Hash of the port.
#   - camelCase to snake_case. A message names the matcher by the name it has
#     here, so the expected text of a message is changed where it names one:
#     arrayWith is array_with.
#   - jest's expect(fn).toThrow(pattern) is assert_thrown, expect(fn).not.toThrow()
#     is the call on its own, and the file's own expectToThrow is kept as it is.
#
# Parity: 85 cases in the origin; 82 ported; 3 not ported.

require "test_helper"
require "ruby_cdk/test"

class CdkAssertionsTemplateTest < Minitest::Test
  # RubyCdk::Test, by a short name.
  T = RubyCdk::Test

  # Template > fromString
  def test_from_string
    template = T::Template.from_string(<<~JSON)
      {
          "Resources": {
            "Foo": {
              "Type": "Baz::Qux",
              "Properties": { "Fred": "Waldo" }
            }
          }
        }
    JSON

    assert_equal({
      "Resources" => {
        "Foo" => {
          "Type" => "Baz::Qux",
          "Properties" => { "Fred" => "Waldo" }
        }
      }
    }, template.to_json)
  end

  # Template > fromStack > default
  def test_from_stack_default
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "Baz" => "Qux" }) } }
    template = T.template(stack)

    assert_equal({
      "Resources" => {
        "Foo" => {
          "Type" => "Foo::Bar",
          "Properties" => { "Baz" => "Qux" }
        }
      }
    }, template.to_json)
  end

  # Template > fromString > default
  def test_from_string_default
    assertions = T::Template.from_string(<<~JSON)
      {
          "Resources": {
            "Foo": {
              "Type": "Baz::Qux",
              "Properties": { "Fred": "Waldo" }
            }
          }
        }
    JSON
    assertions.resource_count_is("Baz::Qux", 1)
  end

  # Template > resourceCountIs > resource exists
  def test_resource_count_is_resource_exists
    stack = { "Resources" => { "Resource" => resource("Foo::Bar") } }

    inspect = T.template(stack)
    inspect.resource_count_is("Foo::Bar", 1)

    assert_thrown("Expected 0 resources of type Foo::Bar but found 1") { inspect.resource_count_is("Foo::Bar", 0) }
    assert_thrown("Expected 2 resources of type Foo::Bar but found 1") { inspect.resource_count_is("Foo::Bar", 2) }

    assert_thrown("Expected 1 resources of type Foo::Baz but found 0") { inspect.resource_count_is("Foo::Baz", 1) }
  end

  # Template > resourceCountIs > no resource
  def test_resource_count_is_no_resource
    stack = {}

    inspect = T.template(stack)
    inspect.resource_count_is("Foo::Bar", 0)

    assert_thrown("Expected 1 resources of type Foo::Bar but found 0") { inspect.resource_count_is("Foo::Bar", 1) }
  end

  # Template > resourcePropertiesCountIs > resource exists
  def test_resource_properties_count_is_resource_exists
    stack = { "Resources" => { "Resource" => resource("Foo::Bar", { "baz" => "qux" }) } }

    inspect = T.template(stack)
    inspect.resource_properties_count_is("Foo::Bar", { "baz" => "qux" }, 1)

    assert_thrown("Expected 0 resources of type Foo::Bar but found 1") do
      inspect.resource_properties_count_is("Foo::Bar", { "baz" => "qux" }, 0)
    end
    assert_thrown("Expected 2 resources of type Foo::Bar but found 1") do
      inspect.resource_properties_count_is("Foo::Bar", { "baz" => "qux" }, 2)
    end
    assert_thrown("Expected 1 resources of type Foo::Bar but found 0") do
      inspect.resource_properties_count_is("Foo::Bar", { "baz" => "nope" }, 1)
    end
    assert_thrown("Expected 1 resources of type Foo::Baz but found 0") do
      inspect.resource_properties_count_is("Foo::Baz", { "baz" => "qux" }, 1)
    end
  end

  # Template > resourcePropertiesCountIs > no resource
  def test_resource_properties_count_is_no_resource
    stack = {}

    inspect = T.template(stack)
    inspect.resource_properties_count_is("Foo::Bar", { "baz" => "qux" }, 0)

    assert_thrown("Expected 1 resources of type Foo::Bar but found 0") do
      inspect.resource_properties_count_is("Foo::Bar", { "baz" => "qux" }, 1)
    end
  end

  # Template > resourcePropertiesCountIs > absent - with properties
  def test_resource_properties_count_is_absent_with_properties
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux" }) } }

    inspect = T.template(stack)
    inspect.resource_properties_count_is("Foo::Bar", {
      "bar" => T.absent
    }, 1)
    inspect.resource_properties_count_is("Foo::Bar", {
      "baz" => T.absent
    }, 0)
  end

  # Template > resourcePropertiesCountIs > absent - no properties
  def test_resource_properties_count_is_absent_no_properties
    stack = { "Resources" => { "Foo" => resource("Foo::Bar") } }

    inspect = T.template(stack)
    inspect.resource_properties_count_is("Foo::Bar", {
      "bar" => T.absent,
      "baz" => "qux"
    }, 0)
    inspect.resource_properties_count_is("Foo::Bar", T.absent, 1)
  end

  # Template > resourcePropertiesCountIs > not - with properties
  def test_resource_properties_count_is_not_with_properties
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux" }) } }

    inspect = T.template(stack)
    inspect.resource_properties_count_is("Foo::Bar", T.not_({
      "baz" => "boo"
    }), 1)
  end

  # Template > resourcePropertiesCountIs > not - no properties
  def test_resource_properties_count_is_not_no_properties
    stack = { "Resources" => { "Foo" => resource("Foo::Bar") } }

    inspect = T.template(stack)
    inspect.resource_properties_count_is("Foo::Bar", T.not_({
      "baz" => "qux"
    }), 1)
  end

  # Template > templateMatches > matches
  def test_template_matches_matches
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux" }) } }

    inspect = T.template(stack)
    inspect.template_matches({
      "Resources" => {
        "Foo" => {
          "Type" => "Foo::Bar",
          "Properties" => { "baz" => "qux" }
        }
      }
    })
  end

  # Template > templateMatches > fails
  def test_template_matches_fails
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux" }) } }

    inspect = T.template(stack)
    assert_thrown(/Expected waldo but received qux/) do
      inspect.template_matches({
        "Resources" => {
          "Foo" => {
            "Type" => "Foo::Bar",
            "Properties" => { "baz" => "waldo" }
          }
        }
      })
    end
  end

  # Template > hasResource > exact match
  def test_has_resource_exact_match
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux" }) } }

    inspect = T.template(stack)
    inspect.has_resource("Foo::Bar", {
      "Properties" => { "baz" => "qux" }
    })

    assert_thrown(/Expected waldo but received qux/) do
      inspect.has_resource("Foo::Bar", {
        "Properties" => { "baz" => "waldo" }
      })
    end

    assert_thrown(/Missing key/) do
      inspect.has_resource("Foo::Bar", {
        "Properties" => { "baz" => "qux", "fred" => "waldo" }
      })
    end
  end

  # Template > hasResource > arrayWith
  def test_has_resource_array_with
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => [ "qux", "quy" ] }) } }

    inspect = T.template(stack)
    inspect.has_resource("Foo::Bar", {
      "Properties" => { "baz" => T.array_with([ "qux" ]) }
    })

    assert_thrown(/Could not match array_with pattern 0/) do
      inspect.has_resource("Foo::Bar", {
        "Properties" => { "baz" => T.array_with([ "waldo" ]) }
      })
    end
  end

  # Template > hasResource > arrayWith - multiple resources
  def test_has_resource_array_with_multiple_resources
    stack = { "Resources" => {
      "Foo1" => resource("Foo::Bar", { "foo" => [ "flob", "qux" ] }),
      "Foo2" => resource("Foo::Bar", { "flob" => [ "qux" ] })
    } }

    inspect = T.template(stack)

    expect_to_throw([ /closest matches/, /flob/, /qux/ ]) do
      inspect.has_resource("Foo::Bar", {
        "Properties" => T.array_with([ "flob" ])
      })
    end
  end

  # Template > hasResource > objectLike
  def test_has_resource_object_like
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }) } }

    inspect = T.template(stack)
    inspect.has_resource("Foo::Bar", {
      "Properties" => T.object_like({ "baz" => "qux" })
    })
    inspect.has_resource("Foo::Bar", {
      "Properties" => T.object_like({ "fred" => "waldo" })
    })

    assert_thrown(/Expected waldo but received qux/) do
      inspect.has_resource("Foo::Bar", {
        "Properties" => T.object_like({ "baz" => "waldo" })
      })
    end
  end

  # Template > hasResource > objectLike - multiple resources
  def test_has_resource_object_like_multiple_resources
    stack = { "Resources" => {
      "Foo1" => resource("Foo::Bar", { "foo" => { "flob" => "qux" } }),
      "Foo2" => resource("Foo::Bar", { "flob" => "waldo" })
    } }

    inspect = T.template(stack)

    expect_to_throw([ /closest match/, /"flob": "qux"/ ]) do
      inspect.has_resource("Foo::Bar", {
        "Properties" => T.object_like({ "foo" => { "flob" => "foo" } })
      })
    end
  end

  # Template > hasResource > absent
  def test_has_resource_absent
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux" }) } }

    inspect = T.template(stack)
    inspect.has_resource("Foo::Bar", {
      "Properties" => T.object_like({ "foo" => T.absent })
    })
    assert_thrown(/key should be absent/) do
      inspect.has_resource("Foo::Bar", {
        "Properties" => T.object_like({ "baz" => T.absent })
      })
    end
  end

  # Template > hasResource > incorrect types
  def test_has_resource_incorrect_types
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }) } }

    inspect = T.template(stack)
    assert_thrown(/0 resources with type Foo::Baz/) do
      inspect.has_resource("Foo::Baz", {
        "Properties" => T.object_like({ "baz" => "qux" })
      })
    end
  end

  # Template > hasResource > capture
  def test_has_resource_capture
    stack = { "Resources" => {
      "Bar1" => resource("Foo::Bar", { "baz" => "qux", "real" => true }),
      "Bar2" => resource("Foo::Bar", { "baz" => "waldo", "real" => true }),
      "Bar3" => resource("Foo::Bar", { "baz" => "fred", "real" => false })
    } }

    capture = T::Capture.new
    inspect = T.template(stack)
    inspect.has_resource("Foo::Bar", {
      "Properties" => T.object_like({ "baz" => capture, "real" => true })
    })

    assert_equal "qux", capture.as_string
    assert_equal true, capture.next
    assert_equal "waldo", capture.as_string
    assert_equal false, capture.next
  end

  # Template > hasResourceProperties > exact match
  def test_has_resource_properties_exact_match
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux" }) } }

    inspect = T.template(stack)
    inspect.has_resource_properties("Foo::Bar", { "baz" => "qux" })

    assert_thrown(/Expected waldo but received qux/) { inspect.has_resource_properties("Foo::Bar", { "baz" => "waldo" }) }

    assert_thrown(/Missing key/) { inspect.has_resource_properties("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }) }
  end

  # Template > hasResourceProperties > absent - with properties
  def test_has_resource_properties_absent_with_properties
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux" }) } }

    inspect = T.template(stack)

    inspect.has_resource_properties("Foo::Bar", {
      "bar" => T.absent
    })

    assert_thrown(/key should be absent/) do
      inspect.has_resource_properties("Foo::Bar", {
        "baz" => T.absent
      })
    end
  end

  # Template > hasResourceProperties > absent - no properties
  def test_has_resource_properties_absent_no_properties
    stack = { "Resources" => { "Foo" => resource("Foo::Bar") } }

    inspect = T.template(stack)

    assert_thrown(/Missing key/) { inspect.has_resource_properties("Foo::Bar", { "bar" => T.absent, "baz" => "qux" }) }

    inspect.has_resource_properties("Foo::Bar", T.absent)
  end

  # Template > hasResourceProperties > not - with properties
  def test_has_resource_properties_not_with_properties
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux" }) } }

    inspect = T.template(stack)
    inspect.has_resource_properties("Foo::Bar", T.not_({
      "baz" => "boo"
    }))
  end

  # Template > hasResourceProperties > not - no properties
  def test_has_resource_properties_not_no_properties
    stack = { "Resources" => { "Foo" => resource("Foo::Bar") } }

    inspect = T.template(stack)
    inspect.has_resource_properties("Foo::Bar", T.not_({ "baz" => "qux" }))
  end

  # Template > getResources > matching resource type
  def test_find_resources_matching_resource_type
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }) } }

    inspect = T.template(stack)
    assert_equal({
      "Foo" => {
        "Type" => "Foo::Bar",
        "Properties" => { "baz" => "qux", "fred" => "waldo" }
      }
    }, inspect.find_resources("Foo::Bar"))
  end

  # Template > getResources > no matching resource type
  def test_find_resources_no_matching_resource_type
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }) } }

    inspect = T.template(stack)
    assert_equal({}, inspect.find_resources("Foo::Baz"))
  end

  # Template > getResources > matching resource props
  def test_find_resources_matching_resource_props
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }) } }

    inspect = T.template(stack)
    assert_equal 1, inspect.find_resources("Foo::Bar", {
      "Properties" => { "baz" => "qux" }
    }).keys.length
  end

  # Template > getResources > no matching resource props
  def test_find_resources_no_matching_resource_props
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }) } }

    inspect = T.template(stack)
    assert_equal({}, inspect.find_resources("Foo::Bar", {
      "Properties" => { "baz" => "waldo" }
    }))
  end

  # Template > getResources > multiple matching resources
  def test_find_resources_multiple_matching_resources
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar"),
      "Bar" => resource("Foo::Bar")
    } }

    inspect = T.template(stack)
    result = inspect.find_resources("Foo::Bar")
    assert_equal 2, result.keys.length
    assert_equal({ "Type" => "Foo::Bar" }, result["Foo"])
    assert_equal({ "Type" => "Foo::Bar" }, result["Bar"])
  end

  # Template > getResourceId > matching resource type
  def test_get_resource_id_matching_resource_type
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }) } }

    inspect = T.template(stack)
    assert_equal "Foo", inspect.get_resource_id("Foo::Bar")
  end

  # Template > getResourceId > no matching resource type
  def test_get_resource_id_no_matching_resource_type
    stack = { "Resources" => { "Foo" => resource("Foo::Baz", { "baz" => "qux", "fred" => "waldo" }) } }

    inspect = T.template(stack)
    expect_to_throw([
      "Template has 0 resources with type Foo::Bar"
    ]) do
      inspect.get_resource_id("Foo::Bar")
    end
  end

  # Template > getResourceId > matching resource props
  def test_get_resource_id_matching_resource_props
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }) } }

    inspect = T.template(stack)
    assert_equal "Foo", inspect.get_resource_id("Foo::Bar", { "Properties" => { "fred" => "waldo" } })
  end

  # Template > getResourceId > no matching resource props
  def test_get_resource_id_no_matching_resource_props
    stack = { "Resources" => { "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }) } }

    inspect = T.template(stack)
    expect_to_throw([
      "Template has 1 resources with type Foo::Bar, but none match as expected",
      /Expected quz but received qux/
    ]) do
      inspect.get_resource_id("Foo::Bar", { "Properties" => { "baz" => "quz" } })
    end
  end

  # Template > getResourceId > multiple matching resources
  def test_get_resource_id_multiple_matching_resources
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar"),
      "Bar" => resource("Foo::Bar")
    } }

    inspect = T.template(stack)
    expect_to_throw([
      "Template has 2 matches, expected only one.",
      /Foo/, /Foo::Bar/,
      /Bar/, /Foo::Bar/
    ]) do
      inspect.get_resource_id("Foo::Bar")
    end
  end

  # Template > getResourceId > multiple matching resources props
  def test_get_resource_id_multiple_matching_resources_props
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }),
      "Bar" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" })
    } }

    inspect = T.template(stack)
    expect_to_throw([
      "Template has 2 matches, expected only one.",
      /Foo/, /Foo::Bar/,
      /Bar/, /Foo::Bar/
    ]) do
      inspect.get_resource_id("Foo::Bar", { "Properties" => { "baz" => "qux" } })
    end
  end

  # Template > getResourceId > multiple resources only one match
  def test_get_resource_id_multiple_resources_only_one_match
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar", { "baz" => "qux", "fred" => "waldo" }),
      "Bar" => resource("Foo::Bar", { "bax" => "qux", "fred" => "waldo" })
    } }

    inspect = T.template(stack)
    assert_equal "Bar", inspect.get_resource_id("Foo::Bar", { "Properties" => { "bax" => "qux" } })
  end

  # Template > allResources > all resource of type match
  def test_all_resources_all_resource_of_type_match
    partial_props = { "baz" => "qux", "fred" => "waldo" }
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar", partial_props.merge({ "lorem" => "ipsum" })),
      "Foo2" => resource("Foo::Bar", partial_props)
    } }

    inspect = T.template(stack)
    inspect.all_resources("Foo::Bar", { "Properties" => partial_props })
  end

  # Template > allResources > no resources match
  def test_all_resources_no_resources_match
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar", { "lorem" => "ipsum" }),
      "Foo2" => resource("Foo::Bar", { "baz" => "qux" })
    } }

    inspect = T.template(stack)
    expect_to_throw([
      "Template has 2 resource(s) with type Foo::Bar, but none match as expected.",
      "The following resources do not match the given definition:",
      /Foo/,
      /Foo2/
    ]) do
      inspect.all_resources("Foo::Bar", { "Properties" => { "fred" => "waldo" } })
    end
  end

  # Template > allResources > some resources match
  def test_all_resources_some_resources_match
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar", { "lorem" => "ipsum" }),
      "Foo2" => resource("Foo::Bar", { "baz" => "qux" })
    } }

    inspect = T.template(stack)
    expect_to_throw([
      "Template has 2 resource(s) with type Foo::Bar, but only 1 match as expected.",
      "The following resources do not match the given definition:",
      /Foo2/
    ]) do
      inspect.all_resources("Foo::Bar", { "Properties" => { "lorem" => "ipsum" } })
    end
  end

  # Template > allResources > using a "not" matcher
  def test_all_resources_using_a_not_matcher
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar", { "lorem" => "ipsum" }),
      "Foo2" => resource("Foo::Bar", { "baz" => "baz" })
    } }

    inspect = T.template(stack)
    inspect.all_resources("Foo::Bar", T.not_({ "Properties" => { "baz" => "qux" } }))
  end

  # Template > allResourcesProperties > all resource of type match
  def test_all_resources_properties_all_resource_of_type_match
    partial_props = { "baz" => "qux", "fred" => "waldo" }
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar", partial_props.merge({ "lorem" => "ipsum" })),
      "Foo2" => resource("Foo::Bar", partial_props)
    } }

    inspect = T.template(stack)
    inspect.all_resources_properties("Foo::Bar", partial_props)
  end

  # Template > allResourcesProperties > no resources match
  def test_all_resources_properties_no_resources_match
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar", { "lorem" => "ipsum" }),
      "Foo2" => resource("Foo::Bar", { "baz" => "qux" }),
      "NotFoo" => resource("NotFoo::NotBar", { "fred" => "waldo" })
    } }

    inspect = T.template(stack)
    expect_to_throw([
      "Template has 2 resource(s) with type Foo::Bar, but none match as expected.",
      "The following resources do not match the given definition:",
      /Foo/,
      /Foo2/
    ]) do
      inspect.all_resources_properties("Foo::Bar", { "fred" => "waldo" })
    end
  end

  # Template > allResourcesProperties > some resources match
  def test_all_resources_properties_some_resources_match
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar", { "lorem" => "ipsum" }),
      "Foo2" => resource("Foo::Bar", { "baz" => "qux" })
    } }

    inspect = T.template(stack)
    expect_to_throw([
      "Template has 2 resource(s) with type Foo::Bar, but only 1 match as expected.",
      "The following resources do not match the given definition:",
      /Foo2/
    ]) do
      inspect.all_resources_properties("Foo::Bar", { "lorem" => "ipsum" })
    end
  end

  # Template > allResourcesProperties > using a "not" matcher
  def test_all_resources_properties_using_a_not_matcher
    stack = { "Resources" => {
      "Foo" => resource("Foo::Bar", { "lorem" => "ipsum" }),
      "Foo2" => resource("Foo::Bar", { "baz" => "baz" })
    } }

    inspect = T.template(stack)
    inspect.all_resources_properties("Foo::Bar", T.not_({ "baz" => "qux" }))
  end

  # Template > hasOutput > matching
  def test_has_output_matching
    stack = { "Outputs" => {
      "Foo" => output("Bar"),
      "Fred" => output("Waldo")
    } }

    inspect = T.template(stack)
    inspect.has_output("Foo", { "Value" => "Bar" })
  end

  # Template > hasOutput > not matching
  def test_has_output_not_matching
    stack = { "Outputs" => {
      "Foo" => output("Bar", { "Export" => { "Name" => "ExportBar" } }),
      "Fred" => output("Waldo")
    } }

    inspect = T.template(stack)
    expect_to_throw([
      /1 outputs named Foo/,
      /Expected ExportBaz but received ExportBar/
    ]) do
      inspect.has_output("Foo", {
        "Value" => "Bar",
        "Export" => { "Name" => "ExportBaz" }
      })
    end
  end

  # Template > hasOutput > value not matching with outputName
  def test_has_output_value_not_matching_with_output_name
    stack = { "Outputs" => {
      "Foo" => output("Bar"),
      "Fred" => output("Baz")
    } }

    inspect = T.template(stack)
    expect_to_throw([
      /1 outputs named Fred/,
      /Expected Bar but received Baz/
    ]) do
      inspect.has_output("Fred", {
        "Value" => "Bar"
      })
    end
  end

  # Template > outputName not matching
  def test_output_name_not_matching
    stack = { "Outputs" => {
      "Foo" => output("Bar", { "Export" => { "Name" => "ExportBar" } })
    } }

    inspect = T.template(stack)
    expect_to_throw([
      /Template has 0 outputs named Fred./
    ]) do
      inspect.has_output("Fred", {
        "Value" => "Bar",
        "Export" => { "Name" => "ExportBar" }
      })
    end
  end

  # Template > findOutputs > matching
  def test_find_outputs_matching
    stack = { "Outputs" => {
      "Foo" => output("Fred", { "Description" => "FooFred" }),
      "Bar" => output("Fred", { "Description" => "BarFred" }),
      "Baz" => output("Waldo", { "Description" => "BazWaldo" })
    } }

    inspect = T.template(stack)
    result = inspect.find_outputs("*", { "Value" => "Fred" })
    assert_equal 2, result.keys.length
    assert_equal({ "Value" => "Fred", "Description" => "FooFred" }, result["Foo"])
    assert_equal({ "Value" => "Fred", "Description" => "BarFred" }, result["Bar"])
  end

  # Template > findOutputs > not matching
  def test_find_outputs_not_matching
    stack = { "Outputs" => {
      "Foo" => output("Fred")
    } }

    inspect = T.template(stack)
    result = inspect.find_outputs("*", { "Value" => "Waldo" })
    assert_equal 0, result.keys.length
  end

  # Template > findOutputs > matching specific output
  def test_find_outputs_matching_specific_output
    stack = { "Outputs" => {
      "Foo" => output("Fred"),
      "Baz" => output("Waldo")
    } }

    inspect = T.template(stack)
    result = inspect.find_outputs("Foo", { "Value" => "Fred" })
    assert_equal({
      "Foo" => {
        "Value" => "Fred"
      }
    }, result)
  end

  # Template > findOutputs > not matching specific output
  def test_find_outputs_not_matching_specific_output
    stack = { "Outputs" => {
      "Foo" => output("Fred"),
      "Baz" => output("Waldo")
    } }

    inspect = T.template(stack)
    result = inspect.find_outputs("Foo", { "Value" => "Waldo" })
    assert_equal 0, result.keys.length
  end

  # Template > hasMapping > matching
  def test_has_mapping_matching
    stack = { "Mappings" => {
      "Foo" => {
        "Foo" => { "Bar" => "Lightning", "Fred" => "Waldo" },
        "Baz" => { "Bar" => "Qux" }
      },
      "Fred" => {
        "Foo" => { "Bar" => "Lightning" }
      }
    } }

    inspect = T.template(stack)
    inspect.has_mapping("*", { "Foo" => { "Bar" => "Lightning" } })
  end

  # Template > hasMapping > not matching
  def test_has_mapping_not_matching
    stack = { "Mappings" => {
      "Foo" => {
        "Foo" => { "Bar" => "Fred", "Baz" => "Waldo" },
        "Qux" => { "Bar" => "Fred" }
      },
      "Fred" => {
        "Foo" => { "Baz" => "Baz" }
      }
    } }

    inspect = T.template(stack)
    expect_to_throw([
      /2 mappings/,
      /Expected Qux but received Fred/
    ]) do
      inspect.has_mapping("*", {
        "Foo" => { "Bar" => "Qux" }
      })
    end
  end

  # Template > hasMapping > matching specific outputName
  def test_has_mapping_matching_specific_output_name
    stack = { "Mappings" => {
      "Foo" => {
        "Foo" => { "Bar" => "Lightning", "Fred" => "Waldo" },
        "Baz" => { "Bar" => "Qux" }
      },
      "Fred" => {
        "Foo" => { "Bar" => "Lightning" }
      }
    } }

    inspect = T.template(stack)
    inspect.has_mapping("Foo", { "Baz" => { "Bar" => "Qux" } })
  end

  # Template > hasMapping > not matching specific outputName
  def test_has_mapping_not_matching_specific_output_name
    stack = { "Mappings" => {
      "Foo" => {
        "Foo" => { "Bar" => "Fred", "Baz" => "Waldo" },
        "Qux" => { "Bar" => "Fred" }
      },
      "Fred" => {
        "Foo" => { "Baz" => "Baz" }
      }
    } }

    inspect = T.template(stack)
    expect_to_throw([
      /1 mappings/,
      /Expected Fred but received Baz/
    ]) do
      inspect.has_mapping("Fred", {
        "Foo" => { "Baz" => "Fred" }
      })
    end
  end

  # Template > findParameters > matching
  def test_find_parameters_matching
    stack = { "Parameters" => {
      "p1" => parameter("String", "string parameter"),
      "p2" => parameter("Number", "number parameter")
    } }

    inspect = T.template(stack)
    result = inspect.find_parameters("*", { "Type" => "String" })
    assert_equal({
      "p1" => {
        "Description" => "string parameter",
        "Type" => "String"
      }
    }, result)
  end

  # Template > findParameters > not matching
  def test_find_parameters_not_matching
    stack = { "Parameters" => {
      "p1" => parameter("String", "string parameter")
    } }

    inspect = T.template(stack)
    result = inspect.find_parameters("*", { "Type" => "Number" })
    assert_equal 0, result.keys.length
  end

  # Template > findParameters > matching with specific parameter name
  def test_find_parameters_matching_with_specific_parameter_name
    stack = { "Parameters" => {
      "p1" => parameter("String", "string parameter"),
      "p2" => parameter("Number", "number parameter")
    } }

    inspect = T.template(stack)
    result = inspect.find_parameters("p1", { "Type" => "String" })
    assert_equal({
      "p1" => {
        "Description" => "string parameter",
        "Type" => "String"
      }
    }, result)
  end

  # Template > findParameters > not matching specific parameter name
  def test_find_parameters_not_matching_specific_parameter_name
    stack = { "Parameters" => {
      "p1" => parameter("String", "string parameter"),
      "p2" => parameter("Number", "number parameter")
    } }

    inspect = T.template(stack)
    result = inspect.find_parameters("p3", { "Type" => "String" })
    assert_equal 0, result.keys.length
  end

  # Template > hasParameter > matching
  def test_has_parameter_matching
    stack = { "Parameters" => {
      "p1" => parameter("String", "string parameter"),
      "p2" => parameter("Number", "number parameter")
    } }

    inspect = T.template(stack)
    inspect.find_parameters("p3", { "Type" => "String" })
  end

  # Template > hasParameter > not matching
  def test_has_parameter_not_matching
    stack = { "Parameters" => {
      "p1" => parameter("String", "string parameter"),
      "p2" => parameter("Number", "number parameter"),
      # The third parameter is part of what the CDK's default synthesizer adds.
      "BootstrapVersion" => {
        "Type" => "AWS::SSM::Parameter::Value<String>",
        "Default" => "/cdk-bootstrap/hnb659fds/version",
        "Description" => "Version of the CDK Bootstrap resources in this environment, automatically retrieved from SSM Parameter Store. [cdk:skip]"
      }
    } }

    inspect = T.template(stack)
    expect_to_throw([
      /3 parameters/,
      /Expected CommaDelimitedList but received String/
    ]) do
      inspect.has_parameter("*", { "Type" => "CommaDelimitedList" })
    end
  end

  # Template > hasParameter > matching specific parameter name
  def test_has_parameter_matching_specific_parameter_name
    stack = { "Parameters" => {
      "p1" => parameter("String", "string parameter"),
      "p2" => parameter("Number", "number parameter")
    } }

    inspect = T.template(stack)
    inspect.find_parameters("p1", { "Type" => "String" })
  end

  # Template > hasParameter > not matching specific parameter name
  def test_has_parameter_not_matching_specific_parameter_name
    stack = { "Parameters" => {
      "p1" => parameter("String", "string parameter"),
      "p2" => parameter("Number", "number parameter")
    } }

    inspect = T.template(stack)
    expect_to_throw([
      /1 parameter/,
      /Expected CommaDelimitedList but received Number/
    ]) do
      inspect.has_parameter("p2", { "Type" => "CommaDelimitedList" })
    end
  end

  # Template > findMappings > matching
  def test_find_mappings_matching
    stack = { "Mappings" => {
      "Foo" => {
        "Foo" => { "Bar" => "Lightning", "Fred" => "Waldo" },
        "Baz" => { "Bar" => "Qux" }
      },
      "Fred" => {
        "Foo" => { "Bar" => "Lightning" }
      }
    } }

    inspect = T.template(stack)
    result = inspect.find_mappings("*", { "Foo" => { "Bar" => "Lightning" } })
    assert_equal({
      "Foo" => {
        "Foo" => { "Bar" => "Lightning", "Fred" => "Waldo" },
        "Baz" => { "Bar" => "Qux" }
      },
      "Fred" => { "Foo" => { "Bar" => "Lightning" } }
    }, result)
  end

  # Template > findMappings > not matching
  def test_find_mappings_not_matching
    stack = { "Mappings" => {
      "Foo" => {
        "Foo" => { "Bar" => "Fred", "Baz" => "Waldo" }
      }
    } }

    inspect = T.template(stack)
    result = inspect.find_mappings("*", { "Foo" => { "Bar" => "Waldo" } })
    assert_equal 0, result.keys.length
  end

  # Template > findMappings > matching with specific outputName
  def test_find_mappings_matching_with_specific_output_name
    stack = { "Mappings" => {
      "Foo" => {
        "Foo" => { "Bar" => "Lightning", "Fred" => "Waldo" },
        "Baz" => { "Bar" => "Qux" }
      },
      "Fred" => {
        "Foo" => { "Bar" => "Lightning" }
      }
    } }

    inspect = T.template(stack)
    result = inspect.find_mappings("Foo", { "Foo" => { "Bar" => "Lightning" } })
    assert_equal({
      "Foo" => {
        "Foo" => { "Bar" => "Lightning", "Fred" => "Waldo" },
        "Baz" => { "Bar" => "Qux" }
      }
    }, result)
  end

  # Template > findMappings > not matching specific output name
  def test_find_mappings_not_matching_specific_output_name
    stack = { "Mappings" => {
      "Foo" => {
        "Foo" => { "Bar" => "Lightning", "Fred" => "Waldo" },
        "Baz" => { "Bar" => "Qux" }
      },
      "Fred" => {
        "Foo" => { "Bar" => "Lightning" }
      }
    } }

    inspect = T.template(stack)
    result = inspect.find_mappings("Fred", { "Baz" => { "Bar" => "Qux" } })
    assert_equal 0, result.keys.length
  end

  # Template > hasCondition > matching
  def test_has_condition_matching
    stack = { "Conditions" => {
      "Foo" => { "Fn::Equals" => [ "Bar", "Baz" ] }
    } }

    inspect = T.template(stack)
    inspect.has_condition("*", { "Fn::Equals" => [ "Bar", "Baz" ] })
  end

  # Template > hasCondition > not matching
  def test_has_condition_not_matching
    stack = { "Conditions" => {
      "Foo" => { "Fn::Equals" => [ "Bar", "Baz" ] },
      "Qux" => { "Fn::Not" => [ { "Fn::Equals" => [ "Quux", "Quuz" ] } ] }
    } }

    inspect = T.template(stack)
    expect_to_throw([
      /2 conditions/,
      /Missing key/
    ]) do
      inspect.has_condition("*", {
        "Fn::Equals" => [ "Baz", "Bar" ]
      })
    end
  end

  # Template > hasCondition > matching specific outputName
  def test_has_condition_matching_specific_output_name
    stack = { "Conditions" => {
      "Foo" => { "Fn::Equals" => [ "Bar", "Baz" ] }
    } }

    inspect = T.template(stack)
    inspect.has_condition("Foo", { "Fn::Equals" => [ "Bar", "Baz" ] })
  end

  # Template > hasCondition > not matching specific outputName
  def test_has_condition_not_matching_specific_output_name
    stack = { "Conditions" => {
      "Foo" => { "Fn::Equals" => [ "Baz", "Bar" ] }
    } }

    inspect = T.template(stack)
    expect_to_throw([
      /1 conditions/,
      /Expected Baz but received Bar/
    ]) do
      inspect.has_condition("Foo", {
        "Fn::Equals" => [ "Bar", "Baz" ]
      })
    end
  end

  # Template > findConditions > matching
  def test_find_conditions_matching
    stack = { "Conditions" => {
      "Foo" => { "Fn::Equals" => [ "Bar", "Baz" ] },
      "Qux" => { "Fn::Not" => [ { "Fn::Equals" => [ "Quux", "Quuz" ] } ] }
    } }

    inspect = T.template(stack)
    first_condition = inspect.find_conditions("Foo")
    assert_equal({
      "Foo" => {
        "Fn::Equals" => [
          "Bar",
          "Baz"
        ]
      }
    }, first_condition)

    second_condition = inspect.find_conditions("Qux")
    assert_equal({
      "Qux" => {
        "Fn::Not" => [
          {
            "Fn::Equals" => [
              "Quux",
              "Quuz"
            ]
          }
        ]
      }
    }, second_condition)
  end

  # Template > findConditions > not matching
  def test_find_conditions_not_matching
    stack = { "Conditions" => {
      "Foo" => { "Fn::Equals" => [ "Bar", "Baz" ] }
    } }

    inspect = T.template(stack)
    result = inspect.find_conditions("Bar")
    assert_equal 0, result.keys.length
  end

  # Template > findConditions > matching with specific outputName
  def test_find_conditions_matching_with_specific_output_name
    stack = { "Conditions" => {
      "Foo" => { "Fn::Equals" => [ "Bar", "Baz" ] }
    } }

    inspect = T.template(stack)
    result = inspect.find_conditions("Foo", { "Fn::Equals" => [ "Bar", "Baz" ] })
    assert_equal({
      "Foo" => {
        "Fn::Equals" => [
          "Bar",
          "Baz"
        ]
      }
    }, result)
  end

  # Template > findConditions > not matching specific output name
  def test_find_conditions_not_matching_specific_output_name
    stack = { "Conditions" => {
      "Foo" => { "Fn::Equals" => [ "Bar", "Baz" ] }
    } }

    inspect = T.template(stack)
    result = inspect.find_conditions("Foo", { "Fn::Equals" => [ "Bar", "Qux" ] })
    assert_equal 0, result.keys.length
  end

  # Template > throws when given a template with cyclic dependencies
  def test_throws_when_given_a_template_with_cyclic_dependencies
    assert_thrown(/dependency cycle/) do
      T.from_json({
        "Resources" => {
          "Res1" => {
            "Type" => "Foo",
            "Properties" => {
              "Thing" => { "Ref" => "Res2" }
            }
          },
          "Res2" => {
            "Type" => "Foo",
            "DependsOn" => [ "Res1" ]
          }
        }
      })
    end
  end

  # Template > throws when given a more complex template with cyclic dependencies
  def test_throws_when_given_a_more_complex_template_with_cyclic_dependencies
    assert_thrown(/dependency cycle/) do
      T.from_json({
        "Resources" => {
          "Res1" => {
            "Type" => "Foo",
            "Properties" => {
              "Thing" => { "Ref" => "Res2" }
            }
          },
          "Res2" => {
            "Type" => "Foo",
            "DependsOn" => [ "Res3" ]
          },
          "Res3" => {
            "Type" => "Foo",
            "DependsOn" => [ "Res2" ]
          }
        }
      })
    end
  end

  # Template > throws when given a template with cyclic dependencies if skipCyclicalDependenciesCheck is false
  def test_throws_when_given_a_template_with_cyclic_dependencies_if_skip_cyclical_dependencies_check_is_false
    assert_thrown(/dependency cycle/) do
      T.from_json({
        "Resources" => {
          "Res1" => {
            "Type" => "Foo",
            "Properties" => {
              "Thing" => { "Ref" => "Res2" }
            }
          },
          "Res2" => {
            "Type" => "Foo",
            "DependsOn" => [ "Res1" ]
          }
        }
      }, skip_cyclical_dependencies_check: false)
    end
  end

  # Template > does not throw when given a template with cyclic dependencies if skipCyclicalDependenciesCheck is true
  def test_does_not_throw_when_given_a_template_with_cyclic_dependencies_if_skip_cyclical_dependencies_check_is_true
    T.from_json({
      "Resources" => {
        "Res1" => {
          "Type" => "Foo",
          "Properties" => {
            "Thing" => { "Ref" => "Res2" }
          }
        },
        "Res2" => {
          "Type" => "Foo",
          "DependsOn" => [ "Res1" ]
        }
      }
    }, skip_cyclical_dependencies_check: true)
  end

  private

  # What `new CfnResource(stack, id, { type, properties })` writes: Type first,
  # Properties when there are any.
  def resource(type, properties = nil)
    properties ? { "Type" => type, "Properties" => properties } : { "Type" => type }
  end

  # What `new CfnOutput(stack, id, { value, ...extra })` writes.
  def output(value, extra = {})
    { "Value" => value }.merge(extra)
  end

  # What `new CfnParameter(stack, id, { type, description })` writes.
  def parameter(type, description)
    { "Type" => type, "Description" => description }
  end

  # jest's expect(fn).toThrow(pattern): the block throws, and the message of what
  # it throws matches the pattern, a Regexp or a substring, when one is given.
  def assert_thrown(pattern = nil)
    error = assert_raises(T::AssertionError, StandardError) { yield }
    if pattern
      pattern.is_a?(Regexp) ? assert_match(pattern, error.message) : assert_includes(error.message, pattern)
    end
    error
  end

  # The file's own expectToThrow.
  def expect_to_throw(msgs)
    yield
    raise Minitest::Assertion, "Function expected to throw, did not throw"
  rescue Minitest::Assertion, StandardError => error
    message = error.message
    unmatching = msgs.reject do |msg|
      msg.is_a?(Regexp) ? msg.match?(message) : message.include?(msg)
    end

    if unmatching.length > 0
      raise Minitest::Assertion, [
        "Error thrown did not contain expected messages: #{unmatching.inspect}",
        "Received error: #{message}"
      ].join("\n")
    end
  end
end
