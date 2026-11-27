# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/aws-ssm/test/parameter.test.ts, in aws/aws-cdk
#   Commit:  c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-27)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 57 test declarations and two test.each tables of three rows
# each: 63 cases. The CDK's StringParameter and StringListParameter are one
# construct here, RubyCdk::SSM::Parameter, with type: :string or :string_list.
#
# What changed to get there:
#
#   - The origin's `new cdk.Stack()` is `stack` here, `Template.fromStack` is
#     `template`; the logical ID is the ids above the resource joined, never
#     hashed (D-004, D-029): Parameter9E1B4FBA is ParameterResource.
#   - stringValue is value:, parameterName is name:, stringListValue is an
#     Array value: with type: :string_list.
#   - The ARN is one Fn::Sub over CloudFormation's pseudo parameters, where
#     the CDK renders Fn::Join over the same five parts. The leading slash of
#     a path name is dropped, so simple name and path name read the same
#     string; the CDK distinguishes the two shapes and this tool writes one.
#
# Not ported, with the reason:
#
#   Not ported because this tool does not have the feature:
#   - type cannot be specified as AWS_EC2_IMAGE_ID. The CDK's type prop is
#     deprecated and this tool takes no deprecated surface: type: takes
#     :string or :string_list and refuses the rest, with a refusal test of
#     its own under test/unit/constructs.
#   - the from* family and everything it feeds: fromStringParameterName (and
#     its lazy CfnParameter), fromStringParameterArn (six cases: the ARN
#     itself, laziness, token ARNs, unexpected format, region agreement,
#     annotation), fromStringParameterAttributes (plain, with version from
#     token, list type throw, correct value, correct value with valueType),
#     fromSecureStringParameterAttributes (plain, version from token,
#     without version), the two encryption-key grant cases,
#     StringListParameter.fromName, fromListParameterAttributes (correct
#     value, not-read laziness), valueForTypedStringParameter,
#     valueForTypedListParameter (plain, with type), the string type and
#     string valueType cases, the SsmParameterValue token, de-dup by name,
#     and can query actual SSM Parameter Names multiple times. Lookups of
#     existing resources are not in 0.1.0 (D-022).
#   - fromLookup, three cases. The same D-022: no AWS call at synthesis.
#   - if parameterName is a token separator must be specified; fails if name
#     is a token and no explicit separator; fails if simpleName is wrong
#     based on a concrete physical name; fails if parameterName is undefined
#     and simpleName is "false". No tokens here, and simpleName has no
#     counterpart: the ARN is one shape (see above).
#   - When a parameter name contains a CFn intrinsic, use dynamic reference
#     instead; When a parameter representation overridden, use dynamic
#     reference. These read a stack parameter of an AWS::SSM::Parameter::Value
#     type, which is a different mechanism this wave does not carry.
#
# Parity: 63 cases in the origin; 22 ported; 41 not ported; 18 tests.

require "test_helper"
require "support/cdk_constructs"

class CdkConstructsSSMParameterTest < CdkConstructs::TestCase
  def test_creating_a_string_ssm_parameter
    built = stack do
      RubyCdk::SSM::Parameter.new(self, "Parameter",
        allowed_pattern: ".*",
        description: "The value Foo",
        name: "FooParameter",
        value: "Foo")
    end

    template(built).has_resource_properties("AWS::SSM::Parameter", {
      "AllowedPattern" => ".*",
      "Description" => "The value Foo",
      "Name" => "FooParameter",
      "Type" => "String",
      "Value" => "Foo"
    })
  end

  def test_data_type_can_be_specified
    built = stack do
      RubyCdk::SSM::Parameter.new(self, "myParam", value: "myValue", data_type: "aws:ec2:image")
    end

    template(built).has_resource_properties("AWS::SSM::Parameter", {
      "Value" => "myValue",
      "DataType" => "aws:ec2:image"
    })
  end

  def test_expect_string_ssm_parameter_to_have_tier_properly_set
    built = stack do
      RubyCdk::SSM::Parameter.new(self, "Parameter",
        allowed_pattern: ".*",
        description: "The value Foo",
        name: "FooParameter",
        value: "Foo",
        tier: :advanced)
    end

    template(built).has_resource_properties("AWS::SSM::Parameter", {
      "Tier" => "Advanced"
    })
  end

  def test_string_ssm_parameter_rejects_invalid_values
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::SSM::Parameter.new(self, "Parameter", allowed_pattern: "^Bar$", value: "FooBar")
      end
    end

    assert_match(/does not match the specified allowedPattern/, error.message)
  end

  def test_string_ssm_parameter_allows_unresolved_tokens
    built = stack do
      RubyCdk::SSM::Parameter.new(self, "Parameter", allowed_pattern: "^Bar$", value: RubyCdk::Lazy.new { "Foo!" })
    end

    template(built).has_resource_properties("AWS::SSM::Parameter", {
      "Value" => "Foo!"
    })
  end

  def test_creating_a_string_list_ssm_parameter
    built = stack do
      RubyCdk::SSM::Parameter.new(self, "Parameter",
        allowed_pattern: "(Foo|Bar)",
        description: "The values Foo and Bar",
        name: "FooParameter",
        value: [ "Foo", "Bar" ],
        type: :string_list)
    end

    template(built).has_resource_properties("AWS::SSM::Parameter", {
      "AllowedPattern" => "(Foo|Bar)",
      "Description" => "The values Foo and Bar",
      "Name" => "FooParameter",
      "Type" => "StringList",
      "Value" => "Foo,Bar"
    })
  end

  def test_string_ssm_parameter_throws_on_long_descriptions
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::SSM::Parameter.new(self, "Parameter", value: "Foo", description: "x" * 1025)
      end
    end

    assert_match(/Description cannot be longer than 1024 characters./, error.message)
  end

  def test_string_ssm_parameter_throws_on_long_names
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::SSM::Parameter.new(self, "Parameter", value: "Foo", name: "y" * 2049)
      end
    end

    assert_match(/name cannot be longer than 2048 characters./, error.message)
  end

  def test_string_list_ssm_parameter_throws_on_long_descriptions
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::SSM::Parameter.new(self, "Parameter", value: [ "Foo", "Bar" ], type: :string_list,
          description: "x" * 1025)
      end
    end

    assert_match(/Description cannot be longer than 1024 characters./, error.message)
  end

  def test_string_list_ssm_parameter_throws_on_long_names
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::SSM::Parameter.new(self, "Parameter", value: [ "Foo", "Bar" ], type: :string_list,
          name: "y" * 2049)
      end
    end

    assert_match(/name cannot be longer than 2048 characters./, error.message)
  end

  # The origin's test.each table of three names, run as data here.
  def test_string_ssm_parameter_throws_on_invalid_name
    [ "/parameter/with spaces", "charactersOtherThan^allowed", "trying;this" ].each do |parameter_name|
      error = assert_raises(RubyCdk::UsageError) do
        stack do
          RubyCdk::SSM::Parameter.new(self, "Parameter", value: "Foo", name: parameter_name)
        end
      end

      assert_match(/name must only contain letters, numbers, and the following 4 symbols/, error.message)
    end
  end

  def test_string_list_ssm_parameter_throws_on_invalid_name
    [ "/parameter/with spaces", "charactersOtherThan^allowed", "trying;this" ].each do |parameter_name|
      error = assert_raises(RubyCdk::UsageError) do
        stack do
          RubyCdk::SSM::Parameter.new(self, "Parameter", value: [ "Foo" ], type: :string_list, name: parameter_name)
        end
      end

      assert_match(/name must only contain letters, numbers, and the following 4 symbols/, error.message)
    end
  end

  def test_string_list_ssm_parameter_values_cannot_contain_commas
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::SSM::Parameter.new(self, "Parameter", value: [ "Foo,Bar" ], type: :string_list)
      end
    end

    assert_match(/cannot contain the ',' character/, error.message)
  end

  def test_string_list_ssm_parameter_rejects_invalid_values
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::SSM::Parameter.new(self, "Parameter", allowed_pattern: "^(Foo|Bar)$", value: [ "Foo", "FooBar" ],
          type: :string_list)
      end
    end

    assert_match(/does not match the specified allowedPattern/, error.message)
  end

  def test_string_list_ssm_parameter_allows_unresolved_tokens
    built = stack do
      RubyCdk::SSM::Parameter.new(self, "Parameter", allowed_pattern: "^(Foo|Bar)$",
        value: [ "Foo", RubyCdk::Lazy.new { "Baz!" } ], type: :string_list)
    end

    # The origin only asserts the construction does not throw; the resolved
    # template is checked too, and the join of two literals resolves to one
    # string, as the CDK's resolved template shows it.
    template(built).has_resource_properties("AWS::SSM::Parameter", {
      "Value" => "Foo,Baz!"
    })
  end

  def test_parameter_arn_is_crafted_correctly
    # Changed: one Fn::Sub over the pseudo parameters, where the origin
    # resolves an Fn::Join over the same five parts (see the header).
    _, parameter = build do
      RubyCdk::SSM::Parameter.new(self, "Parameter", value: "Foo")
    end

    assert_equal(
      { "Fn::Sub" => [
        "arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter/${ParameterName}",
        { "ParameterName" => { "Ref" => "ParameterResource" } }
      ] },
      parameter.arn
    )
  end

  def test_parameter_name_that_includes_a_slash_must_be_fully_qualified
    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::SSM::Parameter.new(self, "myParam", value: "myValue", name: "path/to/parameter")
      end
    end
    assert_match(/Parameter names must be fully qualified/, error.message)

    error = assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::SSM::Parameter.new(self, "myParam2", value: [ "foo", "bar" ], type: :string_list,
          name: "path/to/parameter2")
      end
    end
    assert_match(%r{Parameter names must be fully qualified \(if they include "/" they must also begin with a "/"\): path/to/parameter2},
      error.message)
  end

  def test_rendering_of_parameter_arns
    # Changed: the origin's constructor half, the ARNs of the parameters this
    # tool can build; the imported ones are not ported (D-022). The leading
    # slash is dropped into one ARN shape (see the header).
    _, parameters = build do
      [ RubyCdk::SSM::Parameter.new(self, "P1", value: "value"),
        RubyCdk::SSM::Parameter.new(self, "P2", value: "hello", name: "/foo/bar"),
        RubyCdk::SSM::Parameter.new(self, "P3", value: "hello", name: "simple-name"),
        RubyCdk::SSM::Parameter.new(self, "P4", value: [ "hello", "world" ], type: :string_list),
        RubyCdk::SSM::Parameter.new(self, "P5", value: [ "hello", "world" ], type: :string_list, name: "/not/simple"),
        RubyCdk::SSM::Parameter.new(self, "P6", value: [ "hello", "world" ], type: :string_list, name: "simple") ]
    end

    expected = lambda do |name_value|
      { "Fn::Sub" => [
        "arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter/${ParameterName}",
        { "ParameterName" => name_value }
      ] }
    end

    assert_equal expected.call({ "Ref" => "P1Resource" }), parameters[0].arn
    assert_equal expected.call("foo/bar"), parameters[1].arn
    assert_equal expected.call("simple-name"), parameters[2].arn
    assert_equal expected.call({ "Ref" => "P4Resource" }), parameters[3].arn
    assert_equal expected.call("not/simple"), parameters[4].arn
    assert_equal expected.call("simple"), parameters[5].arn
  end

  private

  # The origin's `new Stack()`, answering [stack, the block's value].
  def build(&body)
    value = nil
    built = stack do
      value = instance_eval(&body)
    end
    [ built, value ]
  end
end
