# frozen_string_literal: true

# Ported from the CDK's own test 'multiple assets under the same parent'
# (Apache-2.0), read on 2026-11-23 in aws/aws-cdk at commit
# 78649cb7cf7399204ed63f629964779eeaa8b37a,
# packages/aws-cdk-lib/aws-s3-assets/test/asset.test.ts.
#
# Changed: two Records of one directory stand in for two Asset constructs,
# which belong to the builder.
#
# Not ported: the rest of asset.test.ts, which is about the L2 construct:
# parameters in the template, grants, metadata and staging, none of which a
# Record has.

require "test_helper"
require "fileutils"
require "tmpdir"
require "ruby_cdk/assets/record"

class AssetsRecordTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("assets-record")
    File.write(File.join(@dir, "app.rb"), "app")
    FileUtils.mkdir_p(File.join(@dir, "lib"))
    File.write(File.join(@dir, "lib/deep.rb"), "deep")
    File.write(File.join(@dir, "debug.log"), "log")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_build_hashes_the_directory
    record = build(@dir)

    assert_equal File.expand_path(@dir), record.source_path
    assert_equal %w[app.rb lib/deep.rb], record.manifest.map(&:path)
    assert_equal RubyCdk::Assets::Hasher.asset_hash(@dir), record.manifest_hash
    assert_match(/\A[0-9a-f]{64}\z/, record.manifest_hash)
  end

  def test_a_relative_path_is_kept_absolute
    Dir.chdir(File.dirname(@dir)) do
      # The system temporary directory is reached through a symbolic link on macOS: the
      # absolute path is the one File.expand_path gives from here, not this test's spelling of it.
      assert_equal File.expand_path(File.basename(@dir)), build(File.basename(@dir)).source_path
    end
  end

  def test_the_key_is_the_hash_followed_by_zip
    record = build(@dir)

    assert_equal "#{record.manifest_hash}.zip", record.key
  end

  def test_the_excludes_are_kept_and_are_the_record_s_own
    exclude = [ "lib", "*.tmp" ]
    record = build(@dir, exclude: exclude)
    exclude << "app.rb" << "lib"

    assert_equal %w[app.rb], record.manifest.map(&:path)
    assert_equal [ "lib", "*.tmp" ], record.exclude
    assert_predicate record.exclude, :frozen?
    assert_equal %w[app.rb lib/deep.rb], build(@dir).manifest.map(&:path)
  end

  def test_a_record_is_a_frozen_value
    record = build(@dir)

    assert_predicate record, :frozen?
    assert_raises(FrozenError) { record.instance_variable_set(:@source_path, "elsewhere") }
    assert_equal record, build(@dir)
    assert_equal %i[source_path exclude manifest manifest_hash], RubyCdk::Assets::Record.members
  end

  # --- ported from asset.test.ts

  def test_multiple_assets_under_the_same_parent
    first = build(@dir)
    second = build(@dir)

    assert_equal first, second
    assert_equal first.key, second.key
  end

  # --- a directory that changed after it was hashed

  def test_the_same_files_in_another_directory_give_the_same_manifest_hash_and_key
    other = Dir.mktmpdir("assets-record-elsewhere")
    begin
      FileUtils.cp_r(File.join(@dir, "."), other)
      here = build(@dir)
      there = build(other)

      refute_equal here.source_path, there.source_path
      assert_equal here.manifest, there.manifest
      assert_equal here.manifest_hash, there.manifest_hash
      assert_equal here.key, there.key
    ensure
      FileUtils.remove_entry(other)
    end
  end

  def test_expected_hash_accepts_a_directory_that_did_not_change
    recorded = build(@dir).manifest_hash
    File.utime(Time.at(0), Time.at(0), File.join(@dir, "app.rb"))

    assert_equal recorded, build(@dir, expected_hash: recorded).manifest_hash
  end

  def test_expected_hash_refuses_a_directory_that_changed
    recorded = build(@dir).manifest_hash
    File.write(File.join(@dir, "app.rb"), "changed")

    error = assert_raises(RubyCdk::Assets::AssetChangedError) { build(@dir, expected_hash: recorded) }

    assert_match(/changed after it was hashed/, error.message)
    assert_includes error.message, build(@dir).manifest_hash
    assert_includes error.message, recorded
  end

  def test_build_raises_what_the_hasher_raises
    assert_raises(RubyCdk::Assets::SourceNotFoundError) { build(File.join(@dir, "nowhere")) }
    File.symlink("/nonexistent", File.join(@dir, "link"))
    assert_raises(RubyCdk::Assets::SymlinkError) { build(@dir) }
  end

  def test_errors_are_ruby_cdk_errors
    assert_operator RubyCdk::Assets::AssetChangedError, :<, RubyCdk::Error
  end

  private

  def build(path, **options)
    RubyCdk::Assets::Record.build(path, **options)
  end
end
