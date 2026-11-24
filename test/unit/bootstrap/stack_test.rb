# frozen_string_literal: true

# The bootstrap stack alone (architecture section 8): its name and tag, the
# bucket with every property the architecture names, both retention policies,
# the bucket policy's two statements, and the template pinned by the hash of
# its serialized bytes.

require "test_helper"
require "digest"
require "tmpdir"
require "ruby_cdk/bootstrap"
require "ruby_cdk/assets"

class BootstrapStackTest < Minitest::Test
  ACCOUNT = "111122223333"
  REGION = "eu-west-1"
  TARGET = RubyCdk::Env.new(account: ACCOUNT, region: REGION)
  BUCKET = "ruby-cdk-assets-#{ACCOUNT}-#{REGION}"
  BUCKET_ARN = "arn:aws:s3:::#{BUCKET}"
  DEPLOYER = "arn:aws:iam::#{ACCOUNT}:role/deployer"

  def setup
    RubyCdk::App.reset!
  end

  def teardown
    RubyCdk::App.reset!
  end

  def test_the_stack_is_named_ruby_cdk_bootstrap_and_carries_the_tag
    stack = build

    assert_instance_of RubyCdk::Stack, stack
    assert_equal "ruby-cdk-bootstrap", stack.stack_name
    assert_equal [ stack ], app.stacks
    assert_equal({ "ruby-cdk" => RubyCdk::VERSION }, stack.tags)
    assert_equal TARGET, stack.env
  end

  def test_the_bucket_and_every_property_the_architecture_names
    bucket = build.to_template.fetch("Resources").fetch("AssetsBucket")

    assert_equal "AWS::S3::Bucket", bucket.fetch("Type")
    assert_equal BUCKET, bucket.fetch("Properties").fetch("BucketName")
    assert_equal({ "Status" => "Enabled" }, bucket.fetch("Properties").fetch("VersioningConfiguration"))
    assert_equal(
      { "ServerSideEncryptionConfiguration" => [ { "ServerSideEncryptionByDefault" => { "SSEAlgorithm" => "AES256" } } ] },
      bucket.fetch("Properties").fetch("BucketEncryption")
    )
    assert_equal(
      { "BlockPublicAcls" => true, "BlockPublicPolicy" => true, "IgnorePublicAcls" => true, "RestrictPublicBuckets" => true },
      bucket.fetch("Properties").fetch("PublicAccessBlockConfiguration")
    )
    assert_equal(
      { "Id" => "abort-incomplete-multipart-uploads", "Status" => "Enabled",
        "AbortIncompleteMultipartUpload" => { "DaysAfterInitiation" => 1 } },
      bucket.fetch("Properties").fetch("LifecycleConfiguration").fetch("Rules").fetch(0)
    )
    # CloudFormation destroying the stack must not empty the bucket (section 8).
    assert_equal "Retain", bucket.fetch("DeletionPolicy")
    assert_equal "Retain", bucket.fetch("UpdateReplacePolicy")
  end

  def test_the_bucket_policy_denies_without_tls_and_lets_the_deployer_read
    policy = build(deployer_arn: DEPLOYER).to_template.fetch("Resources").fetch("BucketPolicy")

    assert_equal "AWS::S3::BucketPolicy", policy.fetch("Type")
    assert_equal({ "Ref" => "AssetsBucket" }, policy.fetch("Properties").fetch("Bucket"))

    deny, allow = policy.fetch("Properties").fetch("PolicyDocument").fetch("Statement")
    assert_equal "Deny", deny.fetch("Effect")
    assert_equal "*", deny.fetch("Principal")
    assert_equal "s3:*", deny.fetch("Action")
    assert_equal [ BUCKET_ARN, "#{BUCKET_ARN}/*" ], deny.fetch("Resource"), "the bucket and its objects"
    assert_equal({ "Bool" => { "aws:SecureTransport" => "false" } }, deny.fetch("Condition"))

    assert_equal "Allow", allow.fetch("Effect")
    assert_equal({ "AWS" => DEPLOYER }, allow.fetch("Principal"))
    assert_equal "s3:GetObject", allow.fetch("Action")
    assert_equal "#{BUCKET_ARN}/*", allow.fetch("Resource"), "the objects: the asset keys sit at the root"
  end

  def test_without_a_deployer_the_account_itself_is_the_reader
    _deny, allow = policy_statements_of(build)

    assert_equal({ "AWS" => "arn:aws:iam::#{ACCOUNT}:root" }, allow.fetch("Principal"))
  end

  def test_a_blank_deployer_arn_is_refused
    error = assert_raises(RubyCdk::UsageError) { build(deployer_arn: "   ") }

    assert_match(/deployer_arn was given blank/, error.message)
  end

  def test_an_app_without_a_concrete_env_is_refused
    error = assert_raises(RubyCdk::UsageError) { build(env: nil) }

    assert_match(/concrete env/, error.message)
    assert_match(/ruby-cdk-assets-<account>-<region>/, error.message)
    assert_match(/RubyCdk::Env\.new\(account:, region:\)/, error.message)
  end

  def test_the_stack_is_built_in_an_app
    error = assert_raises(RubyCdk::UsageError) { RubyCdk::Bootstrap.stack(app: "not an app") }

    assert_match(/in an App/, error.message)
  end

  def test_the_template_holds_only_the_two_sections
    template = build.to_template

    assert_equal %w[AWSTemplateFormatVersion Resources], template.keys
    assert_equal %w[AssetsBucket BucketPolicy], template.fetch("Resources").keys
  end

  def test_the_bucket_name_is_what_the_assets_component_answers
    # The map keeps bootstrap and assets apart, so the name is computed here and
    # not read from Assets. This pins the two to the same bytes.
    [ [ ACCOUNT, REGION ], [ "999988887777", "us-east-1" ] ].each do |account, region|
      assert_equal RubyCdk::Assets.bucket_name(account, region), RubyCdk::Bootstrap.bucket_name(account, region)
    end

    assert_equal BUCKET, RubyCdk::Bootstrap.bucket_name(ACCOUNT, REGION)
  end

  # The hash pins the serialized bytes of the default bootstrap stack (no
  # --deployer, so the account root reads): the format version, the bucket
  # AssetsBucket with the properties of section 8 above, both Retain policies,
  # and the bucket policy with its two statements — for the env of this test,
  # whose account and region are part of the bytes. Nothing else goes in: no
  # description, no parameters, no outputs, no timestamps. A change to the hash
  # changes the template of every future `ruby-cdk bootstrap`: make it on
  # purpose, and say what changed and why.
  TEMPLATE_SHA256 = "b53e0ea94ef75d114170e29085f97099e3faf6505b0df1d65d976c4e3f3e7e51"

  def test_the_template_is_pinned_byte_for_byte
    bytes = RubyCdk::Synth.synthesize(build).bytes

    assert_equal TEMPLATE_SHA256, Digest::SHA256.hexdigest(bytes)
  end

  private

  def app(env: TARGET)
    @app ||= RubyCdk::App.new(env:, out_dir: File.join(Dir.tmpdir, "ruby-cdk-bootstrap-stack-test"))
  end

  def build(env: TARGET, deployer_arn: nil)
    @app = nil
    RubyCdk::Bootstrap.stack(app: app(env:), deployer_arn:)
  end

  def policy_statements_of(stack)
    stack.to_template.fetch("Resources").fetch("BucketPolicy").fetch("Properties").fetch("PolicyDocument").fetch("Statement")
  end
end
