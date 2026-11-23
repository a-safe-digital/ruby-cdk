# frozen_string_literal: true

# Ported from the CDK CLI's own tests, all Apache-2.0, read on 2026-11-23 in
# aws/aws-cdk-cli at commit eca1b73d682d7763955bec30ab5dd52bbc4327b6:
#
# - packages/@aws-cdk/private-tools/test/zip/zip.test.ts
#   describe('zipDirectory'): 'zips a directory, preserves content, mode, and
#   resets dates', 'produces the same hash for the same content
#   (deterministic)', 'rejects and cleans up when readFile fails', 'rejects
#   when the output file cannot be written'
#   describe('timezone independence (regression)'): 'resets dates and produces
#   identical bytes across timezones'
# - packages/@aws-cdk/cdk-assets-lib/test/archive.test.ts
#   'zipDirectory can take a directory and produce a zip from it',
#   'md5 hash of a zip stays consistent across invocations'
#
# Changed:
# - The zip is built from a Record, a directory hashed first, not from a
#   directory path, so each case starts with Record.build.
# - `unzip` and `diff -bur` are replaced by extracting with rubyzip and
#   comparing the files, and jszip by rubyzip: the date is read as its parts,
#   in local time.
# - The mode kept is 0644 or 0755 from the manifest (architecture section
#   21). The CDK keeps the whole mode of the file.
# - 'rejects and cleans up when readFile fails' makes the file unreadable with
#   chmod instead of mocking fs.readFile. There is no temporary file here, so
#   "cleans up" checks that nothing was written.
# - 'md5 hash of a zip stays consistent across invocations' changes the
#   modification times of the files between its two builds instead of waiting
#   two seconds, and writes to two files: the original gives both the same
#   path, so it compares one file with itself.
# - Time zones are changed through ENV["TZ"] in this process instead of
#   timezone-mock.
# - 'rejects when the output file cannot be written' asserts the class
#   Errno::ENOENT: a Ruby error message does not name its code.
#
# Not ported:
# - zip.test.ts 'follows symlinks' and archive.test.ts 'zipDirectory follows
#   symlinks': a symlink is an error here (architecture section 8). The case
#   'a file replaced by a symbolic link after hashing is refused' stands in.
# - zip.test.ts 'retries on EPERM and reports via eventEmitter', 'rethrows
#   non-EPERM rename errors', 'rejects and cleans up when stat fails' and
#   'rejects when listing the directory fails': they mock rename, stat and the
#   glob. The archive is built in memory from the manifest of the record here,
#   so there is no temporary file, no rename and no listing to fail.
# - zip.test.ts describe('zipString'), 2 cases: this tool has no asset that is
#   a single string.

require "test_helper"
require "digest"
require "fileutils"
require "tmpdir"
require "zip"
require "ruby_cdk/assets/zipper"

class AssetsZipperTest < Minitest::Test
  # The earliest date a zip entry holds, as [year, month, day, hour, minute, second].
  EPOCH = [ 1980, 1, 1, 0, 0, 0 ].freeze

  # Bit 11 of the general purpose flags: the name is UTF-8.
  UTF8_NAME = 0x800
  DEFLATE = 8
  LOCAL_SIGNATURE = 0x04034b50

  def setup
    @staging = Dir.mktmpdir("archive-staging-")
    @extract = Dir.mktmpdir("archive-extract-")
  end

  def teardown
    FileUtils.remove_entry(@staging)
    FileUtils.remove_entry(@extract)
  end

  # --- ported from zip.test.ts, describe('zipDirectory')

  def test_zips_a_directory_preserves_content_mode_and_resets_dates
    # Arrange
    src_dir = File.join(@staging, "src")
    FileUtils.mkdir_p(File.join(src_dir, "sub"))
    File.write(File.join(src_dir, "file1.txt"), "content1")
    File.write(File.join(src_dir, "sub", "file2.txt"), "content2")
    exec_file = File.join(src_dir, "run.sh")
    File.write(exec_file, "#!/bin/sh\necho hi")
    File.chmod(0o755, exec_file)
    zip_file = File.join(@staging, "out.zip")

    # Act
    zipper.write(record(src_dir), zip_file)

    # Assert content
    extract(zip_file, @extract)
    assert_same_tree(src_dir, @extract)

    # Dates reset to deterministic epoch
    dates = open_zip(File.binread(zip_file)) { |zip| zip.entries.map { |entry| date_parts(entry.time) } }

    assert_equal 1, dates.uniq.size
    assert_equal EPOCH, dates.first

    # Executable bit preserved
    mode = File.stat(File.join(@extract, "run.sh")).mode

    assert_operator mode & 0o111, :!=, 0
  end

  def test_produces_the_same_hash_for_the_same_content_deterministic
    src_dir = File.join(@staging, "src")
    write_tree(src_dir, { "a.txt" => "a" })
    zip1 = File.join(@staging, "1.zip")
    zip2 = File.join(@staging, "2.zip")

    zipper.write(record(src_dir), zip1)
    zipper.write(record(src_dir), zip2)

    assert_equal Digest::SHA256.hexdigest(File.binread(zip1)), Digest::SHA256.hexdigest(File.binread(zip2))
  end

  def test_rejects_and_cleans_up_when_read_file_fails
    skip "root reads every file" if Process.euid.zero?

    src_dir = File.join(@staging, "src")
    write_tree(src_dir, { "a.txt" => "a", "secret" => "s" })
    zip_file = File.join(@staging, "out.zip")
    asset = record(src_dir)
    File.chmod(0o000, File.join(src_dir, "secret"))

    error = assert_raises(Errno::EACCES) { zipper.write(asset, zip_file) }

    assert_match(/Permission denied/i, error.message)
    assert_equal [ "src" ], Dir.children(@staging)
  end

  def test_rejects_when_the_output_file_cannot_be_written
    src_dir = File.join(@staging, "src")
    write_tree(src_dir, { "a.txt" => "a" })

    out_zip = File.join(@staging, "missing", "out.zip")
    assert_raises(Errno::ENOENT) { zipper.write(record(src_dir), out_zip) }

    assert_equal [ "src" ], Dir.children(@staging)
    refute File.exist?(out_zip)
  end

  # --- ported from zip.test.ts, describe('timezone independence (regression)')

  # The CDK's bytes once shifted with the time zone. rubyzip encodes the date
  # from its local parts too, so the archive is checked the same way.
  def test_resets_dates_and_produces_identical_bytes_across_timezones
    src_dir = File.join(@staging, "src")
    write_tree(src_dir, { "hello.txt" => "hello world" })
    asset = record(src_dir)

    utc = zip_under_timezone("UTC", asset)
    adelaide = zip_under_timezone("Australia/Adelaide", asset) # +09:30 (half-hour offset)
    pacific = zip_under_timezone("US/Pacific", asset) # negative offset

    # The readable entry date is always the fixed epoch ...
    [ utc, adelaide, pacific ].each { |result| assert_equal EPOCH, result[:date] }

    # ... and the raw archive bytes are identical regardless of timezone
    assert_equal utc[:hash], adelaide[:hash]
    assert_equal utc[:hash], pacific[:hash]
  end

  # --- ported from archive.test.ts

  def test_zip_directory_can_take_a_directory_and_produce_a_zip_from_it
    original_dir = File.join(@staging, "test-archive")
    write_tree(original_dir, { "file.txt" => "content", "subdir/file.txt" => "nested", "executable.txt" => "#!/bin/sh\necho hi" })
    File.chmod(0o755, File.join(original_dir, "executable.txt"))
    zip_file = File.join(@staging, "output.zip")
    extract_dir = File.join(@staging, "extract")
    Dir.mkdir(extract_dir)

    zipper.write(record(original_dir), zip_file)

    # unzip and verify that the resulting tree is the same
    extract(zip_file, extract_dir)
    assert_same_tree(original_dir, extract_dir)

    # inspect the zip file to check that dates are reset
    dates = open_zip(File.binread(zip_file)) { |zip| zip.entries.map { |entry| date_parts(entry.time) } }

    assert_equal EPOCH, dates.first
    assert_equal 1, dates.uniq.size

    # check that mode is preserved
    mode = File.stat(File.join(extract_dir, "executable.txt")).mode

    assert_operator mode & 0o100, :!=, 0
    assert_operator mode & 0o010, :!=, 0
    assert_operator mode & 0o001, :!=, 0
  end

  def test_md5_hash_of_a_zip_stays_consistent_across_invocations
    original_dir = File.join(@staging, "test-archive")
    write_tree(original_dir, { "file.txt" => "content", "subdir/file.txt" => "nested" })
    zip_file1 = File.join(@staging, "output.zip")
    zip_file2 = File.join(@staging, "output-again.zip")
    asset = record(original_dir)

    zipper.write(asset, zip_file1)

    # Instead of the CDK's two-second wait: every file gets another mtime.
    files_under(original_dir).each_with_index do |path, index|
      File.utime(Time.at(1_600_000_000 + (index * 86_400)), Time.at(1_700_000_000 + (index * 86_400)), File.join(original_dir, path))
    end

    zipper.write(asset, zip_file2)

    hash1 = Digest::SHA256.hexdigest(File.binread(zip_file1))
    hash2 = Digest::SHA256.hexdigest(File.binread(zip_file2))

    assert_equal hash1, hash2
  end

  # --- the bytes

  def test_building_the_same_record_twice_gives_identical_bytes
    asset = record(write_asset)

    assert_equal zipper.build(asset), zipper.build(asset)
  end

  def test_the_same_files_under_another_root_give_identical_bytes
    first = write_asset
    second = File.join(@staging, "second", "deeper", "still")
    FileUtils.mkdir_p(second)
    FileUtils.cp_r(File.join(first, "."), second)

    refute_equal record(first).source_path, record(second).source_path
    assert_equal zipper.build(record(first)), zipper.build(record(second))
  end

  def test_the_bytes_do_not_depend_on_rubyzip_s_default_compression_level
    asset = record(write_asset)
    expected = zipper.build(asset)
    previous = Zip.default_compression
    begin
      Zip.default_compression = Zlib::BEST_SPEED

      assert_equal expected, zipper.build(asset)
    ensure
      Zip.default_compression = previous
    end
  end

  def test_entry_names_are_relative_paths_with_forward_slashes_in_manifest_order
    asset = record(write_asset({ "z.rb" => "z", "lib/deep/a.rb" => "a", "a.txt" => "a" }))

    open_zip(zipper.build(asset)) do |zip|
      assert_equal %w[a.txt lib/deep/a.rb z.rb], zip.entries.map(&:name)
      assert zip.entries.none?(&:directory?)
      assert zip.entries.none? { |entry| entry.name.start_with?("/") || entry.name.include?("\\") }
    end
  end

  def test_names_outside_ascii_are_stored_as_utf_8
    name = "lib/naïve/café.rb"
    asset = record(write_asset({ name => "# café\n" }))

    open_zip(zipper.build(asset)) do |zip|
      entry = zip.entries.first

      assert_equal name.b, entry.name
      assert_equal UTF8_NAME, entry.gp_flags
    end
  end

  def test_the_mode_is_stored_in_the_external_attributes
    asset = record(write_asset({ "app.rb" => "app", "bin/run" => "run", "lib/x.rb" => "x" }, executable: "bin/run"))

    open_zip(zipper.build(asset)) do |zip|
      attributes = zip.entries.to_h { |entry| [ entry.name, entry.external_file_attributes ] }

      assert_equal({ "app.rb" => 0o100644 << 16, "bin/run" => 0o100755 << 16, "lib/x.rb" => 0o100644 << 16 }, attributes)
    end
  end

  def test_no_comment_anywhere
    asset = record(write_asset)

    open_zip(zipper.build(asset)) do |zip|
      assert_equal "", zip.comment
      assert zip.entries.all? { |entry| entry.comment == "" }
    end
  end

  # Read from the bytes themselves, without rubyzip's reading of them.
  def test_every_header_field_that_could_vary_is_fixed
    bytes = zipper.build(record(write_asset({ "app.rb" => "app", "bin/run" => "run" }, executable: "bin/run")))
    entries = central_directory(bytes)
    eocd = bytes.rindex("PK\x05\x06".b)

    assert_equal %w[app.rb bin/run], entries.map { |entry| entry[:name].force_encoding(Encoding::UTF_8) }
    entries.each do |entry|
      assert_equal 3, entry[:host], "made on Unix"
      assert_equal 20, entry[:version_needed]
      assert_equal DEFLATE, entry[:method]
      assert_equal 0x0021, entry[:dos_date], "1980-01-01"
      assert_equal 0x0000, entry[:dos_time], "00:00:00"
      assert_equal 0, entry[:internal_attributes], "binary, not text"
      assert_equal "", entry[:extra]
      assert_equal "", entry[:comment]
      assert_equal UTF8_NAME, entry[:flags], "a UTF-8 name; no data descriptor, no encryption"
    end
    assert_equal [ 0o100644 << 16, 0o100755 << 16 ], entries.map { |entry| entry[:external_attributes] }

    # Each local header agrees with its central directory record and carries no extra field.
    entries.each_with_index do |entry, index|
      local = bytes.byteslice(entry[:local_offset], 30).unpack("VvvvvvVVVvv")

      assert_equal entry[:name], bytes.byteslice(entry[:local_offset] + 30, local[9]), "local header #{index}"
      assert_equal [ LOCAL_SIGNATURE, 20, UTF8_NAME, DEFLATE, 0x0000, 0x0021, entry[:crc], entry[:compressed_size],
        entry[:size], local[9], 0 ], local, "local header #{index}"
    end

    # The end of the central directory: this disk, both entries, no comment, nothing after it, no zip64 record.
    assert_equal [ 0, 0, 2, 2 ], bytes.byteslice(eocd + 4, 8).unpack("vvvv")
    assert_equal 0, bytes.byteslice(eocd + 20, 2).unpack1("v")
    assert_equal bytes.bytesize, eocd + 22
    refute_includes bytes, "PK\x06\x06".b
  end

  def test_every_entry_is_a_raw_deflate_stream_at_the_fixed_level_with_its_crc_and_sizes_in_the_header
    files = {
      "data.bin" => (0..255).to_a.pack("C*") * 64 + "\n" + ("x" * 100_000),
      "empty" => "",
      "text.txt" => "text" * 10_000,
      # The one content here whose level-6 stream differs from the stream of every other zlib level.
      "words.txt" => wordy_text
    }
    bytes = zipper.build(record(write_asset(files)))

    open_zip(bytes) do |zip|
      files.each do |name, content|
        entry = zip.find_entry(name)

        assert_equal Zlib.crc32(content), entry.crc, name
        assert_equal content.bytesize, entry.size, name
        assert_equal content.b, entry.get_input_stream(&:read), name
        # The data starts after the 30-byte local header and the name: the local header carries no extra field.
        data_offset = entry.local_header_offset + 30 + entry.name.bytesize
        assert_equal raw_deflate(content), bytes.byteslice(data_offset, entry.compressed_size), name
      end
    end
  end

  def test_the_zip_opens_with_rubyzip_and_every_file_round_trips_byte_for_byte
    files = {
      "app.rb" => "# frozen_string_literal: true\n",
      ".hidden" => "hidden\n",
      "bin/run" => "#!/usr/bin/env ruby\n",
      "empty.txt" => "",
      "lib/deep/naïve/café.rb" => "# café\n",
      "vendor/ext/blob.so" => (0..255).to_a.pack("C*") * 4096
    }
    bytes = zipper.build(record(write_asset(files, executable: "bin/run")))

    assert_equal Encoding::ASCII_8BIT, bytes.encoding
    Dir.mktmpdir("archive-roundtrip-") do |out|
      extract_buffer(bytes, out)
      assert_equal files.keys.sort, files_under(out)
      files.each { |name, content| assert_equal content.b, File.binread(File.join(out, name)), name }
    end
  end

  def test_an_empty_directory_gives_the_empty_archive
    asset = record(Dir.mktmpdir("archive-empty-", @staging))

    assert_equal "PK\x05\x06" + "\x00" * 18, zipper.build(asset)
  end

  def test_write_writes_the_zip_and_answers_the_number_of_bytes
    asset = record(write_asset)
    path = File.join(@staging, "out.zip")

    count = zipper.write(asset, path)

    assert_equal zipper.build(asset), File.binread(path)
    assert_equal File.size(path), count
  end

  # --- the directory since it was hashed

  def test_a_change_in_content_changes_the_hash_and_the_zip
    dir = write_asset
    before = record(dir)
    before_zip = zipper.build(before)
    File.write(File.join(dir, "app.rb"), "changed")
    after = record(dir)

    refute_equal before.manifest_hash, after.manifest_hash
    refute_equal before.key, after.key
    refute_equal before_zip, zipper.build(after)
    assert_raises(RubyCdk::Assets::AssetChangedError) { zipper.build(before) }
  end

  def test_a_file_that_changed_after_hashing_is_refused
    dir = write_asset
    asset = record(dir)
    File.write(File.join(dir, "lib/deep/handler.rb"), "class Handler\n  CHANGED = 1\nend\n")

    error = assert_raises(RubyCdk::Assets::AssetChangedError) { zipper.build(asset) }

    assert_match(%r{lib/deep/handler\.rb changed after the asset was hashed}, error.message)
  end

  def test_a_file_removed_after_hashing_is_refused
    dir = write_asset
    asset = record(dir)
    File.delete(File.join(dir, "app.rb"))

    error = assert_raises(RubyCdk::Assets::AssetChangedError) { zipper.build(asset) }

    assert_match(/app\.rb no longer exists/, error.message)
  end

  def test_the_whole_directory_removed_after_hashing_is_refused
    asset = record(write_asset)
    FileUtils.remove_entry(File.join(@staging, "asset"))

    assert_raises(RubyCdk::Assets::AssetChangedError) { zipper.build(asset) }
  end

  def test_a_file_replaced_by_a_symbolic_link_after_hashing_is_refused
    dir = write_asset({ "app.rb" => "app" })
    asset = record(dir)
    twin = File.join(@staging, "twin.rb")
    FileUtils.mv(File.join(dir, "app.rb"), twin)
    File.symlink(twin, File.join(dir, "app.rb"))

    error = assert_raises(RubyCdk::Assets::AssetChangedError) { zipper.build(asset) }

    assert_match(/app\.rb is no longer a regular file/, error.message)
  end

  def test_a_file_added_after_hashing_is_not_packed
    dir = write_asset({ "app.rb" => "app" })
    asset = record(dir)
    File.write(File.join(dir, "late.rb"), "late")
    FileUtils.mkdir_p(File.join(dir, "late"))
    File.write(File.join(dir, "late/dir.rb"), "late")

    open_zip(zipper.build(asset)) { |zip| assert_equal [ "app.rb" ], zip.entries.map(&:name) }
  end

  def test_the_mode_comes_from_the_manifest_not_from_the_disk
    dir = write_asset({ "app.rb" => "app" })
    asset = record(dir)
    File.chmod(0o755, File.join(dir, "app.rb"))

    open_zip(zipper.build(asset)) do |zip|
      assert_equal 0o100644 << 16, zip.entries.first.external_file_attributes
    end
    refute_equal asset.manifest_hash, record(dir).manifest_hash
  end

  def test_errors_are_ruby_cdk_errors
    assert_operator RubyCdk::Assets::AssetChangedError, :<, RubyCdk::Error
  end

  private

  def zipper
    RubyCdk::Assets::Zipper
  end

  def record(dir)
    RubyCdk::Assets::Record.build(dir)
  end

  def write_tree(dir, tree)
    tree.each do |path, content|
      file = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, content)
    end
  end

  # A small asset directory under the staging directory: dir when given, else "asset".
  def write_asset(tree = { "app.rb" => "# frozen_string_literal: true\n", "lib/deep/handler.rb" => "class Handler\nend\n" },
    dir = File.join(@staging, "asset"), executable: nil)
    write_tree(dir, tree)
    Array(executable).each { |path| File.chmod(0o755, File.join(dir, path)) }
    dir
  end

  def open_zip(bytes, &block)
    # Zip::File.open_buffer answers anything but the value of the block.
    result = nil
    Zip::File.open_buffer(bytes) { |zip| result = block.call(zip) }
    result
  end

  def extract(zip_file, dir)
    Zip::File.open(zip_file) { |zip| zip.extract_all(dir) }
  end

  def extract_buffer(bytes, dir)
    open_zip(bytes) { |zip| zip.extract_all(dir) }
  end

  def files_under(dir)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).select { |path| File.file?(File.join(dir, path)) }.sort
  end

  def assert_same_tree(expected, actual)
    assert_equal files_under(expected), files_under(actual)
    files_under(expected).each { |path| assert FileUtils.compare_file(File.join(expected, path), File.join(actual, path)), path }
  end

  def date_parts(time)
    [ time.year, time.month, time.day, time.hour, time.min, time.sec ]
  end

  # Deflates at level 6 as the architecture document says, not at Zipper's
  # constant: the test, not the code, says which level an asset is deflated at.
  def raw_deflate(content)
    Zlib::Deflate.new(6, -Zlib::MAX_WBITS).deflate(content, Zlib::FINISH)
  end

  # Text with enough near-repeats for the zlib levels to part ways, from a
  # small deterministic generator: no dependence on Random's seeds.
  def wordy_text(count = 5_000)
    words = %w[the quick brown fox jumps over lazy dog end while it ran]
    state = 12_345
    Array.new(count) do
      state = (1_103_515_245 * state + 12_345) & 0x7fffffff
      words[(state >> 16) % words.size]
    end.join(" ")
  end

  def zip_under_timezone(zone, asset)
    previous = ENV["TZ"]
    ENV["TZ"] = zone
    bytes = zipper.build(asset)
    date = open_zip(bytes) { |zip| date_parts(zip.entries.first.time) }

    { hash: Digest::SHA256.hexdigest(bytes), date: date }
  ensure
    ENV["TZ"] = previous
  end

  # The central directory records, read from the bytes: one Hash per entry.
  def central_directory(bytes)
    eocd = bytes.rindex("PK\x05\x06".b)
    count = bytes.byteslice(eocd + 10, 2).unpack1("v")
    offset = bytes.byteslice(eocd + 16, 4).unpack1("V")
    Array.new(count) do
      # signature, made-by version, made-by host, version needed, flags, method, time, date, crc,
      # compressed size, size, name length, extra length, comment length, disk, internal, external, local offset
      fields = bytes.byteslice(offset, 46).unpack("VCCvvvvvVVVvvvvvVV")
      name_length, extra_length, comment_length = fields[11], fields[12], fields[13]
      entry = {
        name: bytes.byteslice(offset + 46, name_length),
        version_made_by: fields[1], host: fields[2], version_needed: fields[3], flags: fields[4], method: fields[5],
        dos_time: fields[6], dos_date: fields[7], crc: fields[8], compressed_size: fields[9], size: fields[10],
        extra: bytes.byteslice(offset + 46 + name_length, extra_length),
        comment: bytes.byteslice(offset + 46 + name_length + extra_length, comment_length),
        internal_attributes: fields[15], external_attributes: fields[16], local_offset: fields[17]
      }
      offset += 46 + name_length + extra_length + comment_length
      entry
    end
  end
end
