# frozen_string_literal: true

# The deploy step of architecture section 8: before any change set, the assets
# a stack resolved are in its bucket. Tested against the fake object store, so
# no client and no credential exists anywhere in this file.

require "test_helper"
require "fileutils"
require "tmpdir"
require "ruby_cdk/assets"
require "ruby_cdk/core"
require_relative "../../support/assets_fake_store"

class AssetsPublishTest < Minitest::Test
  ACCOUNT = "111122223333"
  BUCKET = RubyCdk::Assets.bucket_name(ACCOUNT, "eu-central-1")

  def setup
    RubyCdk::App.reset!
    @dir = Dir.mktmpdir("ruby-cdk-publish")
  end

  def teardown
    RubyCdk::App.reset!
    FileUtils.remove_entry(@dir)
  end

  def test_a_stack_with_an_asset_uploads_its_zip_into_its_bucket
    store = AssetsFakeObjectStore.new.add_bucket(BUCKET)
    asset = stack.asset.zip(directory("lambda", "index.rb" => "puts 1\n"))
    key = asset.key.resolve(stack)

    counts = RubyCdk::Assets.publish(stack, store:, owner: ACCOUNT)

    assert_equal({ uploaded: 1, skipped: 0 }, counts)
    uploads = store.calls_to(:put)
    assert_equal 1, uploads.size
    upload = uploads.first
    assert_equal [ BUCKET, key, ACCOUNT ], [ upload.bucket, upload.key, upload.expected_owner ]
    assert_equal RubyCdk::Assets::Zipper.build(asset.record), upload.body, "what was uploaded is the zip of what was hashed"
  end

  def test_a_stack_with_no_asset_uploads_nothing_and_checks_nothing
    store = AssetsFakeObjectStore.new

    counts = RubyCdk::Assets.publish(stack, store:, owner: ACCOUNT)

    assert_equal({ uploaded: 0, skipped: 0 }, counts)
    assert_empty store.calls
  end

  def test_a_bucket_that_is_not_ours_stops_before_anything_is_uploaded
    store = AssetsFakeObjectStore.new.add_bucket(BUCKET, owner: "999988887777")
    stack.asset.zip(directory("lambda", "index.rb" => "puts 1\n")).key.resolve(stack)

    error = assert_raises(RubyCdk::Assets::BucketUnavailableError) { RubyCdk::Assets.publish(stack, store:, owner: ACCOUNT) }

    assert_equal :foreign, error.state
    assert_empty store.calls_to(:put)
  end

  def test_an_absent_bucket_says_to_bootstrap
    store = AssetsFakeObjectStore.new
    stack.asset.zip(directory("lambda", "index.rb" => "puts 1\n")).key.resolve(stack)

    error = assert_raises(RubyCdk::Assets::BucketUnavailableError) { RubyCdk::Assets.publish(stack, store:, owner: ACCOUNT) }

    assert_equal :absent, error.state
    assert_match(/`ruby-cdk bootstrap`/, error.message)
  end

  def test_what_is_already_there_is_left_alone
    asset = stack.asset.zip(directory("lambda", "index.rb" => "puts 1\n"))
    key = asset.key.resolve(stack)
    store = AssetsFakeObjectStore.new.add_object(BUCKET, key, "the zip of an earlier deploy")

    counts = RubyCdk::Assets.publish(stack, store:, owner: ACCOUNT)

    assert_equal({ uploaded: 0, skipped: 1 }, counts)
    assert_equal "the zip of an earlier deploy", store.body(BUCKET, key)
  end

  def test_an_owner_other_than_the_stack_env_account_is_refused_before_anything_is_checked
    store = AssetsFakeObjectStore.new.add_bucket(BUCKET)
    stack.asset.zip(directory("lambda", "index.rb" => "puts 1\n")).key.resolve(stack)

    error = assert_raises(ArgumentError) { RubyCdk::Assets.publish(stack, store:, owner: "999988887777") }

    assert_match(/env account/, error.message)
    assert_empty store.calls, "a caller that names the wrong account must not reach the store with it"
  end

  private

  def stack
    @stack ||= RubyCdk::Stack.new(RubyCdk::App.new(env: RubyCdk::Env.new(account: ACCOUNT, region: "eu-central-1")), "Web")
  end

  # A directory under the test's own, holding the files: { path => content }.
  def directory(name, files)
    path = File.join(@dir, name)
    files.each do |child, content|
      full = File.join(path, child)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
    path
  end
end
