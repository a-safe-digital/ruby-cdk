# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/deploy"

# Capabilities are computed from the template, never from a flag (architecture
# section 9): CAPABILITY_IAM for the eight IAM resource types CloudFormation
# lists, and CAPABILITY_NAMED_IAM with it when one of them has an explicit name.
class DeployCapabilitiesTest < Minitest::Test
  Capabilities = RubyCdk::Deploy::Capabilities
  IAM = "CAPABILITY_IAM"
  NAMED_IAM = "CAPABILITY_NAMED_IAM"

  # The template, with the resources under Resources by logical ID.
  def capabilities(resources)
    Capabilities.for(JSON.parse(JSON.generate("Resources" => resources.each_with_index.to_h { |resource, index| [ "R#{index}", resource ] })))
  end

  def test_a_template_without_iam_resources_needs_no_capability
    types = %w[AWS::S3::Bucket AWS::DynamoDB::Table AWS::Lambda::Function AWS::SQS::Queue AWS::CloudFormation::WaitHandle]

    assert_equal [], capabilities(types.map { |type| { "Type" => type } }), "no IAM resource among five others"
    assert_equal [], Capabilities.for(JSON.parse("{}")), "no Resources section"
    assert_equal [], Capabilities.for(JSON.parse(%q({"Resources":{"Odd":{"Type":7},"Text":"x"}}))), "entries that are not resources"
  end

  def test_each_of_the_eight_iam_types_needs_capability_iam
    Capabilities::IAM_TYPES.each do |type|
      assert_equal [ IAM ], capabilities([ { "Type" => type } ]), type
    end
    assert_equal 8, Capabilities::IAM_TYPES.length
  end

  def test_an_iam_resource_with_an_explicit_name_needs_the_named_capability_too
    {
      "AWS::IAM::Role" => "RoleName",
      "AWS::IAM::ManagedPolicy" => "ManagedPolicyName",
      "AWS::IAM::User" => "UserName",
      "AWS::IAM::Group" => "GroupName",
      "AWS::IAM::InstanceProfile" => "InstanceProfileName"
    }.each do |type, property|
      named = { "Type" => type, "Properties" => { property => "explicit" } }
      assert_equal [ IAM, NAMED_IAM ], capabilities([ named ]), "#{type} with #{property}"
    end
  end

  def test_an_iam_resource_without_a_name_needs_only_capability_iam
    role = { "Type" => "AWS::IAM::Role", "Properties" => { "AssumeRolePolicyDocument" => { "Statement" => [] } } }

    assert_equal [ IAM ], capabilities([ role ])
  end

  def test_one_named_resource_among_many_decides_for_the_template
    resources = [
      { "Type" => "AWS::S3::Bucket" },
      { "Type" => "AWS::IAM::Role", "Properties" => { "RoleName" => "named" } },
      { "Type" => "AWS::IAM::Policy", "Properties" => { "PolicyName" => "inline" } }
    ]

    assert_equal [ IAM, NAMED_IAM ], capabilities(resources)
  end

  def test_a_name_that_is_only_declared_and_not_set_does_not_count
    role = { "Type" => "AWS::IAM::Role", "Properties" => { "RoleName" => nil } }

    assert_equal [ IAM ], capabilities([ role ])
  end

  def test_a_name_property_on_another_type_does_not_count
    bucket = { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "explicit", "RoleName" => "not here" } }

    assert_equal [], capabilities([ bucket ])
  end

  def test_the_capability_list_always_starts_with_the_plain_one
    assert_equal IAM, Capabilities.for(JSON.parse(%q({"Resources":{"Role":{"Type":"AWS::IAM::Role","Properties":{"RoleName":"r"}}}}))).first
  end
end
