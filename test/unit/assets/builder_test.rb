# frozen_string_literal: true

# The builder is this tool's own: the CDK has no `stack.asset.zip`, its assets
# are bound by constructs. What this holds the builder to is architecture
# section 8: the identity is the manifest hash, the key is "<hash>.zip", the
# bucket is a function of the environment, and nothing is read before the stack
# is resolved.

require "test_helper"
require "fileutils"
require "tmpdir"
require "ruby_cdk/assets"
require "ruby_cdk/core"

class AssetsBuilderTest < Minitest::Test
  TARGET = RubyCdk::Env.new(account: "111122223333", region: "eu-central-1")
  BUCKET = "ruby-cdk-assets-111122223333-eu-central-1"

  def setup
    RubyCdk::App.reset!
    @dir = Dir.mktmpdir("ruby-cdk-builder")
  end

  def teardown
    RubyCdk::App.reset!
    FileUtils.remove_entry(@dir)
  end

  def test_nothing_is_read_before_a_value_is_resolved
    asset = stack.asset.zip(directory("lambda", "index.rb" => "puts 1\n"))

    refute asset.resolved?, "declaring the asset read its files"
    assert_empty stack.asset_hashes, "an asset nobody resolved is in the manifest"

    asset.key.resolve(stack)

    assert asset.resolved?
    assert_equal [ asset.record.manifest_hash ], stack.asset_hashes
  end

  def test_hash_key_bucket_and_location
    asset = stack.asset.zip(directory("lambda", "index.rb" => "puts 1\n"))
    hash = RubyCdk::Assets::Hasher.asset_hash(asset.source_path)

    assert_equal hash, asset.asset_hash.resolve(stack)
    assert_equal "#{hash}.zip", asset.key.resolve(stack)
    assert_equal BUCKET, asset.bucket.resolve(stack)
    assert_equal({ "S3Bucket" => BUCKET, "S3Key" => "#{hash}.zip" }, asset.s3_location.resolve(stack))

    # The identity is not named hash: an asset must still work as a Hash key.
    assert_kind_of Integer, asset.hash
    assert_equal 1, [ asset, asset ].uniq.length
  end

  def test_the_same_files_are_the_same_asset_wherever_they_are
    here = stack.asset.zip(directory("here", "index.rb" => "puts 1\n", "lib/x.rb" => "x\n"))
    there = stack.asset.zip(directory("there", "lib/x.rb" => "x\n", "index.rb" => "puts 1\n"))
    other = stack.asset.zip(directory("other", "index.rb" => "puts 2\n", "lib/x.rb" => "x\n"))

    assert_equal here.asset_hash.resolve(stack), there.asset_hash.resolve(stack)
    refute_equal here.asset_hash.resolve(stack), other.asset_hash.resolve(stack)
  end

  def test_exclude_reaches_the_hasher
    source = directory("docs", "index.rb" => "puts 1\n", "notes.md" => "draft\n")
    plain = stack.asset.zip(directory("plain", "index.rb" => "puts 1\n"))

    assert_equal plain.asset_hash.resolve(stack), stack.asset.zip(source, exclude: [ "*.md" ]).asset_hash.resolve(stack)
    refute_equal plain.asset_hash.resolve(stack), stack.asset.zip(source).asset_hash.resolve(stack)
  end

  def test_an_asset_declared_in_one_stack_is_refused_when_resolved_for_another
    source = directory("lambda", "index.rb" => "puts 1\n")
    declaring = stack
    consumer = RubyCdk::Stack.new(RubyCdk::App.new(env: TARGET, out_dir: File.join(@dir, "elsewhere")), "Consumer")
    asset = declaring.asset.zip(source)

    error = assert_raises(RubyCdk::UsageError) { asset.key.resolve(consumer) }

    assert_match(/declared in stack Web/, error.message)
    assert_match(/resolved for stack Consumer/, error.message, "the names are the declaring stack and the resolving one")
    assert_match(/\.asset\.zip\(/, error.message)
    refute asset.resolved?, "a refused asset read its files"
    assert_empty declaring.asset_hashes
  end

  def test_a_stack_without_an_env_refuses_an_asset
    without_env = stack(env: nil)

    error = assert_raises(RubyCdk::UsageError) { without_env.asset.zip(directory("lambda", "index.rb" => "puts 1\n")) }

    assert_match(/needs a concrete env/, error.message)
    assert_match(/RubyCdk::Env\.new\(account:, region:\)/, error.message)
  end

  def test_a_missing_directory_is_reported_when_resolved
    asset = stack.asset.zip(File.join(@dir, "nowhere"))

    assert_raises(RubyCdk::Assets::SourceNotFoundError) { asset.key.resolve(stack) }
    refute asset.resolved?
    assert_empty stack.asset_hashes
  end

  def test_the_same_directory_twice_is_listed_once
    source = directory("lambda", "index.rb" => "puts 1\n")
    first = stack.asset.zip(source)
    second = stack.asset.zip(source)

    first.key.resolve(stack)
    second.key.resolve(stack)

    assert_equal [ first.record.manifest_hash ], stack.asset_hashes
  end

  def test_a_stack_has_one_builder_and_no_asset_until_it_declares_one
    assert_same stack.asset, stack.asset
    assert_empty stack.asset_hashes
  end

  def test_the_bucket_name
    assert_equal BUCKET, RubyCdk::Assets.bucket_name("111122223333", "eu-central-1")
  end

  def test_nothing_here_is_kept_from_being_a_hash_key
    asset = stack.asset.zip(directory("lambda", "index.rb" => "puts 1\n"))

    assert_kind_of Integer, RubyCdk::Assets::Hasher.hash
    assert_kind_of Integer, asset.hash
  end

  def test_the_records_are_what_the_deploy_step_uploads
    source = directory("lambda", "index.rb" => "puts 1\n")
    stack.asset.zip(source).key.resolve(stack)
    stack.asset.zip(source).key.resolve(stack)
    declared_only = stack.asset.zip(directory("later", "index.rb" => "puts 2\n"))

    records = stack.asset.records

    assert_equal [ "#{RubyCdk::Assets::Hasher.asset_hash(source)}.zip" ], records.map(&:key), "one record per distinct asset that was resolved"
    refute declared_only.resolved?, "an asset nobody resolved was read for the deploy"
  end

  private

  # One stack, "Web", in an App with the target (or with none): the same stack
  # for the whole test.
  def stack(env: TARGET)
    (@stacks ||= {})[env] ||= RubyCdk::Stack.new(RubyCdk::App.new(env:, out_dir: File.join(@dir, "out")), "Web")
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
