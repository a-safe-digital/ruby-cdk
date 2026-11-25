# frozen_string_literal: true

# Mutations of the assets component. Each names the test file that must go
# red once it is applied.
#
# Written by the assets track on 2026-11-23, first as a scratch check outside
# the repository: twelve mutations, each caught by the tests as they stood.
# One of them, the compression level, survived at first, because no test
# pinned level 6; the test was added before the file was committed.
#
# 2026-11-24: manifest_sort_removed added after review, on the fixture with
# "lib.rb" beside "lib/a.txt", where the per-directory walk and the whole-path
# sort disagree.

Mutations.define("zipper/entry_time_is_now", "test/unit/assets/zipper_test.rb") do
  Mutations.swap_constant(RubyCdk::Assets::Zipper, :FIXED_TIME, Time.now)
end

Mutations.define("zipper/compression_level_nine", "test/unit/assets/zipper_test.rb") do
  Mutations.swap_constant(RubyCdk::Assets::Zipper, :COMPRESSION_LEVEL, 9)
end

Mutations.define("zipper/no_utf8_flag", "test/unit/assets/zipper_test.rb") do
  Mutations.swap_constant(RubyCdk::Assets::Zipper, :UTF8_NAME, 0)
end

Mutations.define("zipper/content_not_checked_against_the_manifest", "test/unit/assets/zipper_test.rb") do
  Mutations.singleton(RubyCdk::Assets::Zipper) { def read(record, file) = File.binread(File.join(record.source_path, file.path)) }
end

Mutations.define("hasher/any_executable_bit_makes_0755", "test/unit/assets/hasher_test.rb") do
  Mutations.singleton(RubyCdk::Assets::Hasher) { def mode_for(stat) = (stat.mode & 0o111).zero? ? "0644" : "0755" }
end

Mutations.define("hasher/executable_bit_ignored", "test/unit/assets/hasher_test.rb") do
  Mutations.singleton(RubyCdk::Assets::Hasher) { def mode_for(_stat) = "0644" }
end

Mutations.define("hasher/no_default_excludes", "test/unit/assets/hasher_test.rb") do
  Mutations.swap_constant(RubyCdk::Assets::Hasher, :DEFAULT_EXCLUDES, [].freeze)
end

Mutations.define("hasher/manifest_not_sorted", "test/unit/assets/hasher_test.rb") do
  RubyCdk::Assets::Hasher.singleton_class.class_eval do
    alias_method :sorted_manifest, :manifest
    def manifest(source_path, exclude: []) = sorted_manifest(source_path, exclude: exclude).reverse
  end
end

# The manifest's sort removed, not reversed: the per-directory walk is already
# sorted inside every directory, so removing the whole-path sort only shows on
# files like "lib.rb" and "lib/x.rb", where the two orders disagree.
Mutations.define("hasher/manifest_sort_removed", "test/unit/assets/hasher_test.rb") do
  Mutations.singleton(RubyCdk::Assets::Hasher) do
    def manifest(source_path, exclude: [])
      entries = []
      walk(File.expand_path(usable(source_path)), "", DEFAULT_EXCLUDES + Array(exclude), entries)
      entries.freeze
    end
  end
end

Mutations.define("uploader/owner_never_checked", "test/unit/assets/uploader_test.rb") do
  RubyCdk::Assets::Uploader.class_eval { private def ensure_ours(_bucket) = nil }
end

Mutations.define("uploader/owner_left_out_of_every_call", "test/unit/assets/uploader_test.rb") do
  RubyCdk::Assets::Uploader.class_eval do
    private

    def ensure_ours(bucket)
      return if @store.bucket_state(bucket, expected_owner: nil) == :mine

      raise RubyCdk::Assets::BucketUnavailableError.new(bucket, :absent, @owner)
    end

    def put_unless_present(record, bucket)
      key = record.key
      return :skipped if @store.object_exists?(bucket, key, expected_owner: nil)

      @store.put(bucket, key, body: RubyCdk::Assets::Zipper.build(record), expected_owner: nil)
      :uploaded
    end
  end
end

Mutations.define("uploader/a_present_key_uploaded_again", "test/unit/assets/uploader_test.rb") do
  RubyCdk::Assets::Uploader.class_eval do
    private

    def put_object_unless_present(key, bucket, body)
      @store.put(bucket, key, body: body.call, expected_owner: @owner)
      :uploaded
    end
  end
end

Mutations.define("uploader/no_dedupe", "test/unit/assets/uploader_test.rb") do
  RubyCdk::Assets::Uploader.class_eval do
    def upload_all(records, bucket:)
      counts = { uploaded: 0, skipped: 0 }
      records.each { |record| counts[upload(record, bucket: bucket)] += 1 }
      counts
    end
  end
end
