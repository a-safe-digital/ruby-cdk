# frozen_string_literal: true

# The template half of the deploy step of architecture section 8: a template
# too large for a request is placed in the bucket, and the change set carries
# its address instead of the template. Tested against the fake object store,
# so no client and no credential exists anywhere in this file.

require "test_helper"
require "fileutils"
require "tmpdir"
require "ruby_cdk/assets"
require "ruby_cdk/core"
require_relative "../../support/assets_fake_store"

class AssetsPublishTemplateTest < Minitest::Test
  ACCOUNT = "111122223333"
  REGION = "eu-central-1"
  BUCKET = RubyCdk::Assets.bucket_name(ACCOUNT, REGION)
  TEMPLATE = JSON.generate({ "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" } } })

  def setup
    RubyCdk::App.reset!
    @dir = Dir.mktmpdir("ruby-cdk-publish-template")
  end

  def teardown
    RubyCdk::App.reset!
    FileUtils.remove_entry(@dir)
  end

  def test_a_template_is_put_under_its_hash_and_its_address_is_answered
    store = AssetsFakeObjectStore.new.add_bucket(BUCKET)

    url = RubyCdk::Assets.publish_template(stack, TEMPLATE, store:, owner: ACCOUNT)

    key = "templates/blog/#{Digest::SHA256.hexdigest(TEMPLATE)}.json"
    assert_equal "https://#{BUCKET}.s3.#{REGION}.amazonaws.com/#{key}", url
    puts_of(store).tap do |uploads|
      assert_equal 1, uploads.size
      assert_equal [ BUCKET, key, ACCOUNT ], [ uploads.first.bucket, uploads.first.key, uploads.first.expected_owner ]
    end
    assert_equal TEMPLATE, store.body(BUCKET, key), "what was put is the template as it was given"
  end

  def test_another_template_lands_on_another_key
    store = AssetsFakeObjectStore.new.add_bucket(BUCKET)
    other = JSON.generate({ "Resources" => { "Table" => { "Type" => "AWS::DynamoDB::Table" } } })

    RubyCdk::Assets.publish_template(stack, TEMPLATE, store:, owner: ACCOUNT)
    url = RubyCdk::Assets.publish_template(stack, other, store:, owner: ACCOUNT)

    assert_equal "https://#{BUCKET}.s3.#{REGION}.amazonaws.com/templates/blog/#{Digest::SHA256.hexdigest(other)}.json", url
    assert_equal 2, puts_of(store).size, "one put per distinct template"
  end

  def test_what_is_already_there_is_left_alone_and_its_address_is_answered_all_the_same
    key = "templates/blog/#{Digest::SHA256.hexdigest(TEMPLATE)}.json"
    store = AssetsFakeObjectStore.new.add_object(BUCKET, key, "the bytes of an earlier deploy")

    url = RubyCdk::Assets.publish_template(stack, TEMPLATE, store:, owner: ACCOUNT)

    assert_equal "https://#{BUCKET}.s3.#{REGION}.amazonaws.com/#{key}", url
    assert_empty puts_of(store), "the key is the hash of the body, so what is there is already these bytes"
    assert_equal "the bytes of an earlier deploy", store.body(BUCKET, key)
  end

  def test_an_owner_other_than_the_stack_env_account_is_refused_before_anything_is_checked
    store = AssetsFakeObjectStore.new.add_bucket(BUCKET)

    error = assert_raises(RubyCdk::PreconditionError) { RubyCdk::Assets.publish_template(stack, TEMPLATE, store:, owner: "999988887777") }

    assert_match(/env account/, error.message)
    assert_empty store.calls, "a caller that names the wrong account must not reach the store with it"
  end

  def test_a_bucket_that_is_not_ours_stops_before_anything_is_put
    store = AssetsFakeObjectStore.new.add_bucket(BUCKET, owner: "999988887777")

    error = assert_raises(RubyCdk::Assets::BucketUnavailableError) do
      RubyCdk::Assets.publish_template(stack, TEMPLATE, store:, owner: ACCOUNT)
    end

    assert_equal :foreign, error.state
    assert_empty puts_of(store)
  end

  def test_an_absent_bucket_says_to_bootstrap
    store = AssetsFakeObjectStore.new

    error = assert_raises(RubyCdk::Assets::BucketUnavailableError) do
      RubyCdk::Assets.publish_template(stack, TEMPLATE, store:, owner: ACCOUNT)
    end

    assert_equal :absent, error.state
    assert_match(/`ruby-cdk bootstrap`/, error.message)
  end

  def test_a_stack_without_an_env_has_no_bucket_and_nothing_is_put
    store = AssetsFakeObjectStore.new.add_bucket(BUCKET)
    without_env = RubyCdk::Stack.new(RubyCdk::App.new(out_dir: File.join(@dir, "out")), "Plain")

    error = assert_raises(RubyCdk::PreconditionError) do
      RubyCdk::Assets.publish_template(without_env, TEMPLATE, store:, owner: ACCOUNT)
    end

    assert_match(/no env/, error.message)
    assert_match(/Give the stack an env/, error.message)
    assert_empty store.calls, "without a bucket name, nothing reaches the store"
  end

  private

  def stack
    @stack ||= RubyCdk::Stack.new(RubyCdk::App.new(env: RubyCdk::Env.new(account: ACCOUNT, region: REGION)), "blog")
  end

  def puts_of(store)
    store.calls_to(:put)
  end
end
