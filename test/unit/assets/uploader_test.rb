# frozen_string_literal: true

# Ported from the CDK CLI's own tests, all Apache-2.0, read on 2026-11-23 in
# aws/aws-cdk-cli at commit eca1b73d682d7763955bec30ab5dd52bbc4327b6:
#
# - packages/@aws-cdk/cdk-assets-lib/test/files.test.ts
#   'file already exists with { force: false }', 'upload file if new (list
#   returns other key)', 'will only read bucketEncryption once even for
#   multiple assets', 'fails when we dont have access to the bucket', 'fails
#   when cross account is required but not allowed'
# - packages/@aws-cdk/cdk-assets-lib/test/zipping.test.ts
#   'Take a zipped upload'
#
# Changed:
# - The AWS SDK mock is replaced by an in-memory object store with the three
#   methods of the port, and ListObjectsV2Command by object_exists?.
# - Assets are Records built from a temporary directory, not entries of an
#   assets.json. The object key is "<manifest hash>.zip" instead of 'some_key'.
# - 'will only read bucketEncryption once even for multiple assets': the port
#   has no encryption lookup. The call it counts is bucket_state, made once
#   for two assets.
# - 'fails when we dont have access to the bucket' spells the apostrophe. It
#   and 'fails when cross account is required but not allowed' both reach the
#   uploader as :foreign: the port cannot tell them apart.
# - 'Take a zipped upload' asserts nothing on ContentType: the port's put has
#   none.
#
# Not ported:
# - 'file already exists with { force: true }': there is no force option.
# - 'tiny file does not count as cache hit': the CDK uploads again an object
#   of five bytes or fewer, left behind by older CLIs. Nothing here writes an
#   object smaller than the 22 bytes of an empty zip, and the port answers
#   object_exists? without a size.
# - 'upload with server side encryption AES256 header', 'upload with server
#   side encryption aws:kms header and key id', 'no server side encryption
#   header if access denied for bucket encryption', 'will use SHA256 content
#   checksum' and 'correctly looks up content type': the port's put carries
#   neither a content type, a checksum nor encryption, so they belong to the
#   adapter behind the port.
# - 'successful run does not need to query account ID', 'pass destination
#   properties into AWS client' and 'correctly identify asset path if path is
#   absolute': about account discovery, the client and the asset manifest.
# - 'succeeds when bucket doesnt belong to us but doesnt contain account id -
#   cross account' and 'bucket ownership cache does not leak
#   allowCrossAccount:true result into a later allowCrossAccount:false publish
#   for the same bucket': the expected owner is always named here, and there
#   is no cross-account mode and no cache.
# - describe('external assets'), 2 cases: an asset built by running a command.
#   lib/ starts no process.

require "test_helper"
require "fileutils"
require "tmpdir"
require "zip"
require_relative "../../support/assets_fake_store"
require "ruby_cdk/assets/uploader"

class AssetsUploaderTest < Minitest::Test
  BUCKET = "some_bucket"
  OWNER = "111122223333"
  SOMEBODY_ELSE = "999988887777"

  # Answers something that is not a state of the port.
  class ConfusedStore < AssetsFakeObjectStore
    def bucket_state(name, expected_owner:)
      log(:bucket_state, name, nil, expected_owner)
      :nope
    end
  end

  # Answers something where the port promises a boolean.
  class LyingStore < AssetsFakeObjectStore
    attr_accessor :answer

    def object_exists?(bucket, key, expected_owner:)
      log(:object_exists?, bucket, key, expected_owner)
      @answer
    end
  end

  def setup
    @dirs = []
    @asset = record_of("some_file", "FILE_CONTENTS")
    @store = AssetsFakeObjectStore.new(owner: OWNER).add_bucket(BUCKET)
    @uploader = uploader_for(@store)
  end

  def teardown
    @dirs.each { |dir| FileUtils.rm_rf(dir) }
  end

  # --- ported from files.test.ts

  def test_file_already_exists_with_force_false
    @store.add_object(BUCKET, @asset.key)

    assert_equal :skipped, @uploader.upload(@asset, bucket: BUCKET)

    lookup = @store.calls_to(:object_exists?)
    assert_equal 1, lookup.size
    assert_equal [ BUCKET, @asset.key, OWNER ], [ lookup.first.bucket, lookup.first.key, lookup.first.expected_owner ]
    assert_empty @store.calls_to(:put)
  end

  def test_upload_file_if_new_list_returns_other_key
    @store.add_object(BUCKET, "some_key.but_not_the_one")

    assert_equal :uploaded, @uploader.upload(@asset, bucket: BUCKET)

    # Upload calls PutObjectCommand under the hood
    uploads = @store.calls_to(:put)
    assert_equal 1, uploads.size
    assert_equal [ BUCKET, @asset.key ], [ uploads.first.bucket, uploads.first.key ]
  end

  def test_will_only_read_bucket_encryption_once_even_for_multiple_assets
    other = record_of("other_file", "OTHER_CONTENTS")

    assert_equal({ uploaded: 2, skipped: 0 }, @uploader.upload_all([ @asset, other ], bucket: BUCKET))

    # Upload calls PutObjectCommand under the hood
    assert_equal 2, @store.calls_to(:put).size
    assert_equal 1, @store.calls_to(:bucket_state).size
  end

  def test_fails_when_we_dont_have_access_to_the_bucket
    store = AssetsFakeObjectStore.new(owner: SOMEBODY_ELSE).add_bucket(BUCKET)

    error = assert_raises(RubyCdk::Assets::BucketUnavailableError) { uploader_for(store).upload(@asset, bucket: BUCKET) }

    assert_match(/but we don't have access to it/, error.message)
    assert_equal :foreign, error.state
    assert_equal BUCKET, error.bucket
  end

  def test_fails_when_cross_account_is_required_but_not_allowed
    store = AssetsFakeObjectStore.new(owner: SOMEBODY_ELSE).add_bucket(BUCKET)

    error = assert_raises(RubyCdk::Assets::BucketUnavailableError) { uploader_for(store).upload(@asset, bucket: BUCKET) }

    assert_match(/unexpected bucket owner/i, error.message)
  end

  # --- ported from zipping.test.ts

  def test_take_a_zipped_upload
    assert_equal :uploaded, @uploader.upload(record_of("some_dir/some_file", "FILE_CONTENTS"), bucket: BUCKET)

    # Upload calls PutObjectCommand under the hood
    put = @store.calls_to(:put).first
    assert_equal [ BUCKET, OWNER ], [ put.bucket, put.expected_owner ]

    Zip::File.open_buffer(put.body) do |zip|
      assert_equal [ "some_dir/some_file" ], zip.entries.map(&:name)
      assert_equal "FILE_CONTENTS", zip.entries.first.get_input_stream(&:read)
    end
  end

  # --- the owner on every call

  def test_the_expected_owner_is_passed_on_every_call
    present = record_of("present", "present")
    @store.add_object(BUCKET, present.key)

    @uploader.upload_all([ @asset, present ], bucket: BUCKET)

    assert_equal %i[bucket_state object_exists? put], @store.calls.map(&:name).uniq
    assert @store.calls.all? { |call| call.expected_owner == OWNER }
  end

  def test_a_foreign_bucket_is_refused_before_any_lookup
    store = AssetsFakeObjectStore.new(owner: SOMEBODY_ELSE).add_bucket(BUCKET)

    assert_raises(RubyCdk::Assets::BucketUnavailableError) { uploader_for(store).upload(@asset, bucket: BUCKET) }

    assert_equal %i[bucket_state], store.calls.map(&:name)
    assert_empty store.objects
  end

  def test_an_absent_bucket_is_refused_before_any_lookup_and_names_bootstrap
    store = AssetsFakeObjectStore.new(owner: OWNER)

    error = assert_raises(RubyCdk::Assets::BucketUnavailableError) { uploader_for(store).upload(@asset, bucket: BUCKET) }

    assert_match(/No bucket named 'some_bucket' in account 111122223333/, error.message)
    assert_match(/Run `ruby-cdk bootstrap` first/, error.message)
    assert_equal :absent, error.state
    assert_equal %i[bucket_state], store.calls.map(&:name)
    assert_empty store.objects
  end

  def test_upload_all_refuses_a_foreign_bucket_before_any_lookup
    store = AssetsFakeObjectStore.new(owner: SOMEBODY_ELSE).add_bucket(BUCKET)

    assert_raises(RubyCdk::Assets::BucketUnavailableError) do
      uploader_for(store).upload_all([ @asset, record_of("another", "another") ], bucket: BUCKET)
    end

    assert_equal %i[bucket_state], store.calls.map(&:name)
    assert_empty store.objects
  end

  def test_upload_all_refuses_an_absent_bucket_before_any_lookup
    store = AssetsFakeObjectStore.new(owner: OWNER)

    assert_raises(RubyCdk::Assets::BucketUnavailableError) do
      uploader_for(store).upload_all([ @asset, record_of("another", "another") ], bucket: BUCKET)
    end

    assert_equal %i[bucket_state], store.calls.map(&:name)
    assert_empty store.objects
  end

  def test_a_state_that_is_not_one_of_the_port_is_refused
    store = ConfusedStore.new(owner: OWNER).add_bucket(BUCKET)

    error = assert_raises(RubyCdk::Assets::BucketUnavailableError) { uploader_for(store).upload(@asset, bucket: BUCKET) }

    assert_match(/answered :nope.*neither :mine, :foreign nor :absent/, error.message)
    assert_equal %i[bucket_state], store.calls.map(&:name)
  end

  def test_an_object_exists_answer_that_is_not_true_is_taken_for_absent
    [ "false", 0, nil ].each do |answer|
      store = LyingStore.new(owner: OWNER).add_bucket(BUCKET)
      store.answer = answer

      assert_equal :uploaded, uploader_for(store).upload(@asset, bucket: BUCKET),
        "object_exists? answered #{answer.inspect}"
      assert_equal 1, store.calls_to(:put).size
    end
  end

  # --- counts

  def test_upload_all_reports_the_counts
    present = record_of("present", "present")
    @store.add_object(BUCKET, present.key)
    second = record_of("second", "second")

    assert_equal({ uploaded: 2, skipped: 1 }, @uploader.upload_all([ @asset, present, second ], bucket: BUCKET))
    assert_equal({ uploaded: 0, skipped: 3 }, @uploader.upload_all([ @asset, present, second ], bucket: BUCKET))
    assert_equal 2, @store.calls_to(:put).size
  end

  def test_upload_all_of_nothing_uploads_nothing_and_checks_nothing
    assert_equal({ uploaded: 0, skipped: 0 }, @uploader.upload_all([], bucket: BUCKET))
    assert_empty @store.calls
  end

  # A stack with no assets deploys into an account that was never bootstrapped.
  def test_upload_all_of_nothing_needs_no_bucket
    absent = AssetsFakeObjectStore.new(owner: OWNER)
    foreign = AssetsFakeObjectStore.new(owner: SOMEBODY_ELSE).add_bucket(BUCKET)

    assert_equal({ uploaded: 0, skipped: 0 }, uploader_for(absent).upload_all([], bucket: BUCKET))
    assert_equal({ uploaded: 0, skipped: 0 }, uploader_for(foreign).upload_all([], bucket: BUCKET))
    assert_empty absent.calls
    assert_empty foreign.calls

    # One record is a request: its bucket is still checked.
    assert_raises(RubyCdk::Assets::BucketUnavailableError) { uploader_for(absent).upload(@asset, bucket: BUCKET) }
    assert_raises(RubyCdk::Assets::BucketUnavailableError) { uploader_for(foreign).upload(@asset, bucket: BUCKET) }
  end

  def test_a_key_that_appears_twice_is_uploaded_once
    assert_equal({ uploaded: 1, skipped: 1 }, @uploader.upload_all([ @asset, @asset ], bucket: BUCKET))

    assert_equal 1, @store.calls_to(:put).size
    assert_equal 1, @store.calls_to(:object_exists?).size

    assert_equal({ uploaded: 0, skipped: 2 }, @uploader.upload_all([ @asset, @asset ], bucket: BUCKET))
    assert_equal 1, @store.calls_to(:put).size
  end

  # --- what is read and what is sent

  def test_an_existing_key_is_skipped_without_reading_the_directory
    @store.add_object(BUCKET, @asset.key)
    @dirs.each { |dir| FileUtils.remove_entry(dir) }

    assert_equal :skipped, @uploader.upload(@asset, bucket: BUCKET)
  end

  def test_the_uploaded_body_is_the_zip_of_the_record
    @uploader.upload(@asset, bucket: BUCKET)

    assert_equal RubyCdk::Assets::Zipper.build(@asset), @store.body(BUCKET, @asset.key)
    assert_equal [ [ BUCKET, @asset.key ] ], @store.objects.keys
  end

  def test_a_directory_that_changed_after_hashing_is_not_uploaded
    File.write(File.join(@asset.source_path, "some_file"), "changed")

    assert_raises(RubyCdk::Assets::AssetChangedError) { @uploader.upload(@asset, bucket: BUCKET) }
    assert_empty @store.calls_to(:put)
    assert_empty @store.objects
  end

  # --- arguments

  def test_an_owner_that_is_not_a_12_digit_account_id_is_refused
    [ nil, "", "11112222333", "1111222233334", "abcdefgh1234", " 111122223333" ].each do |owner|
      error = assert_raises(ArgumentError) { RubyCdk::Assets::Uploader.new(store: @store, owner: owner) }

      assert_match(/12-digit/, error.message)
    end
    assert_empty @store.calls
  end

  def test_an_account_id_given_as_a_number_is_kept_as_its_digits
    assert_equal :uploaded, uploader_for(@store, 111122223333).upload(@asset, bucket: BUCKET)

    assert @store.calls.all? { |call| call.expected_owner == "111122223333" }
  end

  def test_a_bucket_without_a_name_is_refused
    [ nil, "", "  " ].each do |bucket|
      assert_raises(ArgumentError) { @uploader.upload(@asset, bucket: bucket) }
    end
    assert_empty @store.calls
  end

  def test_errors_are_ruby_cdk_errors
    assert_operator RubyCdk::Assets::BucketUnavailableError, :<, RubyCdk::Error
  end

  private

  # A record of a new temporary directory holding one file at path.
  def record_of(path, content)
    dir = Dir.mktmpdir("assets-uploader-")
    @dirs << dir
    file = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, content)
    RubyCdk::Assets::Record.build(dir)
  end

  def uploader_for(store, owner = OWNER)
    RubyCdk::Assets::Uploader.new(store: store, owner: owner)
  end
end
