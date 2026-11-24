# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/test"

# This tool's own tests of the dependency-cycle check a template goes through
# when it is built: what it reads as a dependency, and the cycle it names. The
# CDK's own template.test.ts (under test/cdk/assertions) only checks that a cycle
# raises; each case here states what cyclic.ts does, read from its source.
class TestKitCyclicTest < Minitest::Test
  # RubyCdk::Test, by a short name.
  T = RubyCdk::Test

  def test_the_cycle_is_named_in_the_order_it_is_walked
    error = cycle_in({
      "Res1" => { "Type" => "Foo", "Properties" => { "Thing" => { "Ref" => "Res2" } } },
      "Res2" => { "Type" => "Foo", "DependsOn" => [ "Res1" ] }
    })

    assert_equal <<~MESSAGE.chomp, error.message
      Template is undeployable, these resources have a dependency cycle: Res1 -> Res2 -> Res1:

      {
        "Res1": {
          "Type": "Foo",
          "Properties": {
            "Thing": {
              "Ref": "Res2"
            }
          }
        },
        "Res2": {
          "Type": "Foo",
          "DependsOn": [
            "Res1"
          ]
        }
      }
    MESSAGE
  end

  def test_a_cycle_beyond_the_first_resource_is_walked_from_it
    error = cycle_in({
      "Res1" => { "Type" => "Foo", "Properties" => { "Thing" => { "Ref" => "Res2" } } },
      "Res2" => { "Type" => "Foo", "DependsOn" => [ "Res3" ] },
      "Res3" => { "Type" => "Foo", "DependsOn" => [ "Res2" ] }
    })

    assert_match(/\ATemplate is undeployable, these resources have a dependency cycle: Res1 -> Res2 -> Res3 -> Res2:/, error.message)
    [ "Res1", "Res2", "Res3" ].each { |logical_id| assert_includes error.message, "\"#{logical_id}\": {" }
  end

  def test_depends_on_may_be_one_name_or_a_list
    one_name = { "A" => { "Type" => "T", "DependsOn" => "B" }, "B" => { "Type" => "T", "DependsOn" => "A" } }
    list = { "A" => { "Type" => "T", "DependsOn" => [ "B" ] }, "B" => { "Type" => "T", "DependsOn" => [ "A" ] } }

    assert_thrown(/A -> B -> A/) { T.from_json({ "Resources" => one_name }) }
    assert_thrown(/A -> B -> A/) { T.from_json({ "Resources" => list }) }
  end

  def test_a_reference_and_an_attribute_are_dependencies_wherever_they_are
    reference = { "A" => { "Type" => "T", "Properties" => { "Deep" => [ { "Ref" => "B" } ] } }, "B" => { "Type" => "T", "DependsOn" => [ "A" ] } }
    attribute = { "A" => { "Type" => "T", "Properties" => { "Arn" => { "Fn::GetAtt" => [ "B", "Arn" ] } } }, "B" => { "Type" => "T", "DependsOn" => [ "A" ] } }

    assert_thrown(/A -> B -> A/) { T.from_json({ "Resources" => reference }) }
    assert_thrown(/A -> B -> A/) { T.from_json({ "Resources" => attribute }) }
  end

  def test_a_substitution_string_names_the_resources_it_substitutes
    plain = { "A" => { "Type" => "T", "Properties" => { "S" => { "Fn::Sub" => "arn ${B.Arn} and ${C}" } } },
              "B" => { "Type" => "T", "DependsOn" => [ "A" ] }, "C" => { "Type" => "T" } }
    with_context = { "A" => { "Type" => "T", "Properties" => { "S" => { "Fn::Sub" => [ "${X}", { "X" => { "Ref" => "B" } } ] } } },
                     "B" => { "Type" => "T", "DependsOn" => [ "A" ] } }

    assert_thrown(/A -> B -> A/) { T.from_json({ "Resources" => plain }) }
    assert_thrown(/A -> B -> A/) { T.from_json({ "Resources" => with_context }) }
  end

  def test_a_substitution_that_is_not_one_is_no_dependency
    not_one = { "A" => { "Type" => "T", "Properties" => { "S" => { "Fn::Sub" => "literal ${!B}" } } },
                "B" => { "Type" => "T", "DependsOn" => [ "A" ] } }
    after_one = { "A" => { "Type" => "T", "Properties" => { "S" => { "Fn::Sub" => "literal ${!B}, then ${C}" } } },
                  "B" => { "Type" => "T", "DependsOn" => [ "A" ] }, "C" => { "Type" => "T", "DependsOn" => [ "B" ] } }

    T.from_json({ "Resources" => not_one })
    assert_thrown(/A -> C -> B -> A/) { T.from_json({ "Resources" => after_one }) }
  end

  def test_a_name_that_is_not_a_resource_is_no_dependency
    resources = { "A" => { "Type" => "T", "Properties" => { "R" => { "Ref" => "AWS::Region" }, "P" => { "Ref" => "Param" },
                                                               "G" => { "Fn::GetAtt" => [ "Elsewhere.Arn" ] } } } }

    T.from_json({ "Resources" => resources })
    T.from_json({ "Parameters" => { "Param" => { "Type" => "String" } }, "Resources" => resources })
  end

  def test_dependencies_that_do_not_close_a_cycle_pass
    chain = { "A" => { "Type" => "T", "DependsOn" => [ "B" ] }, "B" => { "Type" => "T", "DependsOn" => [ "C" ] }, "C" => { "Type" => "T" } }
    diamond = { "A" => { "Type" => "T", "DependsOn" => [ "B", "C" ] }, "B" => { "Type" => "T", "DependsOn" => [ "D" ] },
                "C" => { "Type" => "T", "DependsOn" => [ "D" ] }, "D" => { "Type" => "T" } }
    two_ways = { "A" => { "Type" => "T", "DependsOn" => [ "B", "C" ] }, "B" => { "Type" => "T", "DependsOn" => [ "D", "E" ] },
                 "C" => { "Type" => "T", "DependsOn" => [ "D", "E" ] }, "D" => { "Type" => "T", "DependsOn" => [ "E" ] }, "E" => { "Type" => "T" } }

    [ chain, diamond, two_ways ].each { |resources| T.from_json({ "Resources" => resources }) }
  end

  def test_a_cycle_away_from_the_first_resource_is_found_once_the_rest_is_removed
    resources = { "A" => { "Type" => "T", "DependsOn" => [ "B" ] }, "B" => { "Type" => "T", "DependsOn" => [ "C" ] },
                  "C" => { "Type" => "T", "DependsOn" => [ "B" ] }, "D" => { "Type" => "T" } }

    assert_thrown(/A -> B -> C -> B:/) { T.from_json({ "Resources" => resources }) }
  end

  def test_a_template_without_resources_passes
    T.from_json({})
    T.from_string("{}")
    T.template({ "Resources" => nil })
  end

  def test_a_substitution_whose_pattern_is_not_a_string_is_skipped
    resources = { "A" => { "Type" => "T", "Properties" => { "S" => { "Fn::Sub" => [ { "Ref" => "B" }, {} ] } } },
                  "B" => { "Type" => "T", "DependsOn" => [ "A" ] } }

    # The pattern is not a string, so it is not read; the context is empty.
    T.from_json({ "Resources" => resources })
  end

  private

  def cycle_in(resources)
    assert_raises(T::AssertionError) { T.from_json({ "Resources" => resources }) }
  end

  def assert_thrown(pattern)
    error = assert_raises(T::AssertionError, StandardError) { yield }
    assert_match pattern, error.message
    error
  end
end
