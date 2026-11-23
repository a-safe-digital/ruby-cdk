# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/lib/index.ts (the public surface of the module)
#           packages/aws-cdk-lib/matching/lib/match.ts (Match)
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: the module is RubyCdk::Test. The factories of Match are module
#   functions of RubyCdk::Test as well, which is where the test plan of this tool
#   writes them; `not` is `not_`, because `not` is a Ruby keyword. template,
#   from_string and from_json stand for Template.fromStack, Template.fromString
#   and Template.fromJSON. Annotations and Tags are not ported: this tool has no
#   synth-time annotations and no Tags aspect.
#
# This file requires nothing else of the gem. It loads alone.

require_relative "test/capture"
require_relative "test/match"
require_relative "test/matcher"
require_relative "test/template"

module RubyCdk
  # What a user's tests ask of a synthesized template: the equivalent of the
  # CDK's aws-cdk-lib/assertions.
  #
  #   template = RubyCdk::Test.template(stack)          # or from_string(json), from_json(hash)
  #   template.resource_count_is(2)
  #   template.has_resource("AWS::S3::Bucket",
  #     "DeletionPolicy" => "RetainExceptOnCreate",
  #     "Properties"     => RubyCdk::Test.object_like("BucketName" => "data"))
  #   template.has_resource_properties("AWS::Lambda::Function",
  #     "Runtime" => "ruby4.0",
  #     "Code"    => { "S3Bucket" => RubyCdk::Test.any_value })
  #   template.get("Resources.Fn.Properties.Timeout").as_number
  #
  # Every method that asserts raises RubyCdk::Test::AssertionError when it fails.
  # In a Minitest run it is a Minitest::Assertion, so the failure is reported as a
  # failure, provided "minitest/autorun" is required before "ruby_cdk/test".
  module Test
    class << self
      # Base your assertions on the CloudFormation template of a stack, of a Hash,
      # or of a JSON string. See RubyCdk::Test::Template.template.
      def template(source, options = {})
        Template.template(source, options)
      end

      # Base your assertions from a CloudFormation template as a JSON string.
      def from_string(template, options = {})
        Template.from_string(template, options)
      end

      # Base your assertions from a CloudFormation template as a Hash.
      def from_json(template, options = {})
        Template.from_json(template, options)
      end

      # Use this matcher in the place of a field's value, if the field must not be present.
      def absent
        Match.absent
      end

      # Matches the specified pattern with the array found in the same relative
      # path of the target. The elements (or matchers) must be in the order they
      # are found in.
      def array_with(pattern)
        Match.array_with(pattern)
      end

      # Matches the specified pattern with the array found in the same relative
      # path of the target. The elements (or matchers) must match exactly and in order.
      def array_equals(pattern)
        Match.array_equals(pattern)
      end

      # Deep exact matching of the specified pattern to the target.
      def exact(pattern)
        Match.exact(pattern)
      end

      # Matches the specified pattern to an object found in the same relative path
      # of the target. The keys and their values (or matchers) must be present in
      # the target, which can be a superset.
      def object_like(pattern)
        Match.object_like(pattern)
      end

      # Matches the specified pattern to an object found in the same relative path
      # of the target. The keys and their values (or matchers) must match exactly.
      def object_equals(pattern)
        Match.object_equals(pattern)
      end

      # Matches any target which does NOT follow the specified pattern.
      # `not_`, because `not` is a Ruby keyword.
      def not_(pattern)
        Match.not_(pattern)
      end

      # Matches any string-encoded JSON and applies the specified pattern after parsing it.
      def serialized_json(pattern)
        Match.serialized_json(pattern)
      end

      # Matches any non-null value at the target.
      def any_value
        Match.any_value
      end

      # Matches targets according to a regular expression.
      def string_like_regexp(pattern)
        Match.string_like_regexp(pattern)
      end
    end
  end
end
