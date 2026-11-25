# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/constructs"
require "ruby_cdk/test"
require "support/core_helpers"

# This tool's own tests of the S3 bucket, what no CDK case reaches here
# (docs/07-testing.md section 10).
class ConstructsBucketTest < CoreHelpers::TestCase
  def test_a_bucket_used_twice_carries_two_distinct_resources
    app = build_app(env: TEST_ENV)
    stack = RubyCdk::Stack.new(app, "stack") do
      RubyCdk::S3::Bucket.new(self, "Bucket", bucket_name: "one-two-three")
      RubyCdk::S3::Bucket.new(self, "Bucket2", bucket_name: "four-five-six")
    end
    template = RubyCdk::Test.template(stack)

    template.resource_count_is("AWS::S3::Bucket", 2)
    template.has_resource_properties("AWS::S3::Bucket", { "BucketName" => "one-two-three" })
    template.has_resource_properties("AWS::S3::Bucket", { "BucketName" => "four-five-six" })
  end

  def test_a_bucket_without_a_name_refers_to_its_resource
    built, bucket = build_stack do
      RubyCdk::S3::Bucket.new(self, "Bucket")
    end

    assert_equal({ "Ref" => "BucketResource" }, bucket.bucket_name)
    # A physical name left out stays out of the template, as the CDK's
    # physicalName does: CloudFormation names the bucket.
    template(built).has_resource_properties("AWS::S3::Bucket", {
      "BucketName" => RubyCdk::Test.absent()
    })
  end

  def test_the_objects_arn_carries_the_pattern
    _, bucket = build_stack do
      RubyCdk::S3::Bucket.new(self, "Bucket")
    end

    assert_equal(
      { "Fn::Join" => [ "", [ { "Fn::GetAtt" => [ "BucketResource", "Arn" ] }, "/home/*" ] ] },
      bucket.objects_arn("home/*")
    )
  end

  def test_public_access_block_takes_a_hash_and_false
    built, = build_stack do
      RubyCdk::S3::Bucket.new(self, "Bucket", public_access_block: { "IgnorePublicAcls" => false })
      RubyCdk::S3::Bucket.new(self, "Bucket2", public_access_block: false)
    end
    template = RubyCdk::Test.template(built)

    template.has_resource_properties("AWS::S3::Bucket", {
      "PublicAccessBlockConfiguration" => RubyCdk::Test.object_equals(
        "BlockPublicAcls" => true,
        "BlockPublicPolicy" => true,
        "IgnorePublicAcls" => false,
        "RestrictPublicBuckets" => true
      )
    })
    template.has_resource_properties("AWS::S3::Bucket", {
      "PublicAccessBlockConfiguration" => RubyCdk::Test.object_equals(
        "BlockPublicAcls" => false,
        "BlockPublicPolicy" => false,
        "IgnorePublicAcls" => false,
        "RestrictPublicBuckets" => false
      )
    })
  end

  def test_a_grant_to_an_arn_principal_is_returned_unapplied
    stack, bucket = build_stack do
      RubyCdk::S3::Bucket.new(self, "Bucket")
    end

    grant = bucket.grant_read("arn:aws:iam::111122223333:user/alice")

    assert_equal "arn:aws:iam::111122223333:user/alice", grant.principal_arn
    refute grant.applied?
    RubyCdk::Test.template(stack).resource_count_is("AWS::IAM::Policy", 0)
  end

  def test_encryption_takes_only_the_two_kinds_or_nil
    built, = build_stack do
      RubyCdk::S3::Bucket.new(self, "Bucket", encryption: nil)
    end

    RubyCdk::Test.template(built).template_matches({ "Resources" => { "BucketResource" => {
      "Type" => "AWS::S3::Bucket",
      "DeletionPolicy" => "RetainExceptOnCreate",
      "UpdateReplacePolicy" => "Retain",
      "Properties" => {
        "PublicAccessBlockConfiguration" => {
          "BlockPublicAcls" => true, "BlockPublicPolicy" => true, "IgnorePublicAcls" => true, "RestrictPublicBuckets" => true
        }
      }
    } } })
  end

  def test_an_unknown_encryption_is_refused
    error = assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::S3::Bucket.new(self, "Bucket", encryption: :unencrypted) }
    end

    assert_match(/encryption takes :s3_managed, :kms_managed or nil/, error.message)
  end

  def test_the_name_validator_collects_every_broken_rule
    short = assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::S3::Bucket.new(self, "Bucket", bucket_name: "a") }
    end
    assert_match(/Invalid S3 bucket name \(value: a\)/, short.message)
    assert_match(/at least 3 and no more than 63/, short.message)

    edges = assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::S3::Bucket.new(self, "Bucket", bucket_name: "-x.") }
    end
    assert_match(/Invalid S3 bucket name \(value: -x\.\)/, edges.message)
    assert_match(/must start with a lowercase character or number \(offset: 0\)/, edges.message)
    assert_match(/must end with a lowercase character or number \(offset: 2\)/, edges.message)
  end

  def test_a_name_that_resembles_an_ip_address_is_refused
    error = assert_raises(RubyCdk::UsageError) do
      build_stack { RubyCdk::S3::Bucket.new(self, "Bucket", bucket_name: "1.2.3.4") }
    end

    assert_match(/must not resemble an IP address/, error.message)
  end

  private

  # One stack in an App with the test env, whose build is the block. Answers
  # [stack, the block's value].
  def build_stack(&body)
    app = build_app(env: TEST_ENV)
    value = nil
    built = RubyCdk::Stack.new(app, "Stack") do
      value = instance_eval(&body)
    end
    [ built, value ]
  end

  def template(stack)
    RubyCdk::Test.template(stack)
  end
end
