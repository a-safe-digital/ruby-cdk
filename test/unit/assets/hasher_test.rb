# frozen_string_literal: true

# Ported from the CDK's own tests, all Apache-2.0, read on 2026-11-23 in
# aws/aws-cdk at commit 78649cb7cf7399204ed63f629964779eeaa8b37a:
#
# - packages/aws-cdk-lib/core/test/fs/fs-fingerprint.test.ts
#   'works on empty files', 'works on directories', 'ignores requested files',
#   'changes with file names'
# - packages/aws-cdk-lib/aws-s3-assets/test/asset.test.ts
#   'fails if path is empty', 'fails if directory not found'
# - packages/aws-cdk-lib/core/test/staging.test.ts
#   'base case', 'base case if source directory is a symlink'
#
# Changed:
# - The hash is of a directory's manifest (relative path, mode 0644 or 0755,
#   content hash), not of content alone (architecture section 21), so 'base
#   case' pins this tool's hash instead of FIXTURE_TEST1_HASH.
# - 'works on empty files' hashes a directory that holds the empty file: a
#   single file is not an asset here.
# - The fixture directories are written in a temporary directory instead of
#   the CDK's fixtures/symlinks, which contain symlinks.
#
# Not ported:
# - fs-fingerprint 'does not change with the file name': it hashes a single
#   file. In a directory the name is part of the hash, which is what
#   'changes with file names' asserts.
# - fs-fingerprint 'changes with negated gitignore patterns inside ignored
#   directories': exclude patterns are plain globs here, with no negation and
#   no gitignore mode.
# - fs-fingerprint describe('symlinks'), 13 cases: the CDK follows symlinks
#   under three modes. Here a symlink is an error (architecture section 8);
#   the cases named "a symbolic link ..." stand in.
# - fs-fingerprint 'normalizes line endings': line endings are content here
#   (architecture section 8); 'line endings are content' stands in.
# - fs-fingerprint describe('fingerprint cache'), 2 cases: there is no cache,
#   and no modification time is ever read.
# - fs-fingerprint 'normalizes relative path': it simulates the Windows
#   path.relative(). Relative paths are built with a slash on every platform.
# - staging.test.ts, the rest: bundling, staging copies, the asset hash cache,
#   salts and custom hashes do not exist here. lib/ starts no process and
#   zipping happens at deploy.

require "test_helper"
require "digest"
require "fileutils"
require "tempfile"
require "tmpdir"
require "ruby_cdk/assets/hasher"

class AssetsHasherTest < Minitest::Test
  # The tree of 'works on directories' and 'changes with file names'.
  TREE = {
    "normal-dir/file-in-subdir.txt" => "file in subdir",
    "file-in-root.txt" => "file in root"
  }.freeze

  # The tree of 'base case', with its manifest text and hash computed by hand
  # from the format: SHA-256 of each file, then of the text.
  FIXTURE = {
    "app.rb" => "# frozen_string_literal: true\n\ndef handler(event:, context:)\n  { statusCode: 200, body: \"hello\" }\nend\n",
    "bin/run" => "#!/bin/sh\necho hi\n",
    "lib/deep/nested.txt" => "nested\n"
  }.freeze
  FIXTURE_TEXT =
    "0644 app.rb f57b0116982216d2cc43d0541f2c10a5953ceebb85a3944f13b4a585bc01fbad\n" \
    "0755 bin/run 299001868fb8c02fd431c336c6d058f5558c5dff5b5af5e6fe04b870a6a9cbba\n" \
    "0644 lib/deep/nested.txt 370a8c04b8a65bb4494275eec227f1b694db04c76da6b0b8ae88ed1ab19790a3\n"
  FIXTURE_HASH = "42ed611bcea6234feeb448b3c96bed17295d164a4ab306a618765f560d102b7f"

  # --- ported from fs-fingerprint.test.ts

  def test_works_on_empty_files
    with_directory do |first|
      File.write(File.join(first, "empty"), "")
      with_directory do |second|
        File.write(File.join(second, "empty"), "")

        assert_equal hasher.asset_hash(first), hasher.asset_hash(second)
      end
    end
  end

  def test_works_on_directories
    with_directory do |srcdir|
      write_tree(srcdir, TREE)
      with_directory do |outdir|
        copy_tree(srcdir, outdir)

        assert_equal hasher.asset_hash(srcdir), hasher.asset_hash(outdir)
      end
    end
  end

  def test_ignores_requested_files
    with_directory do |srcdir|
      write_tree(srcdir, TREE)
      hash_src = hasher.asset_hash(srcdir, exclude: [ "*.ignoreme" ])
      with_directory do |outdir|
        copy_tree(srcdir, outdir)
        File.write(File.join(outdir, "#{hash_src}.ignoreme"), "Ignore me!")

        assert_equal hash_src, hasher.asset_hash(outdir, exclude: [ "*.ignoreme" ])
      end
    end
  end

  def test_changes_with_file_names
    with_directory do |srcdir|
      write_tree(srcdir, TREE)
      with_directory do |cpydir|
        copy_tree(srcdir, cpydir)

        # be careful not to break a symlink
        File.rename(File.join(cpydir, "normal-dir", "file-in-subdir.txt"), File.join(cpydir, "move-me.txt"))

        refute_equal hasher.asset_hash(srcdir), hasher.asset_hash(cpydir)
      end
    end
  end

  # --- ported from asset.test.ts

  def test_fails_if_path_is_empty
    error = assert_raises(RubyCdk::Assets::SourceNotFoundError) { hasher.manifest("") }

    assert_match(/Asset path cannot be empty/, error.message)
  end

  def test_fails_if_directory_not_found
    error = assert_raises(RubyCdk::Assets::SourceNotFoundError) do
      hasher.manifest(File.join(Dir.tmpdir, "path/not/found/#{rand(999_999)}"))
    end

    assert_match(/Cannot find asset/, error.message)
  end

  # --- ported from staging.test.ts

  def test_base_case
    with_directory do |dir|
      write_tree(dir, FIXTURE)
      File.chmod(0o755, File.join(dir, "bin/run"))

      assert_equal FIXTURE_HASH, hasher.asset_hash(dir)
      assert_equal FIXTURE_TEXT, hasher.canonical(hasher.manifest(dir))
      assert_equal Digest::SHA256.hexdigest(FIXTURE_TEXT), hasher.asset_hash(dir)
    end
  end

  def test_base_case_if_source_directory_is_a_symlink
    with_directory do |dir|
      write_tree(dir, FIXTURE)
      File.chmod(0o755, File.join(dir, "bin/run"))
      with_directory do |other|
        source_path = File.join(other, "asset-symlink")
        File.symlink(dir, source_path)

        # Should be the same asset hash as in the previous test
        assert_equal FIXTURE_HASH, hasher.asset_hash(source_path)
      end
    end
  end

  # --- the manifest and the hash format

  def test_the_manifest_lists_every_file_sorted_by_relative_path_with_its_mode_and_content_hash
    with_directory do |dir|
      # "lib.rb" sorts before "lib/...": the manifest is sorted by the whole
      # path, which the per-directory walk alone would not give, because its
      # root children put the directory "lib" before the file "lib.rb".
      write_tree(dir, FIXTURE.merge("lib/a.txt" => "a", "lib.rb" => "lib", "z.rb" => "z", "é.rb" => "é"))
      File.chmod(0o755, File.join(dir, "bin/run"))

      manifest = hasher.manifest(dir)

      assert_equal %w[app.rb bin/run lib.rb lib/a.txt lib/deep/nested.txt z.rb é.rb], manifest.map(&:path)
      assert_equal %w[0644 0755 0644 0644 0644 0644 0644], manifest.map(&:mode)
      assert_equal manifest.map(&:path).map { |path| sha256(File.binread(File.join(dir, path))) }, manifest.map(&:sha256)
    end
  end

  def test_relative_paths_are_utf_8_with_forward_slashes
    with_directory do |dir|
      write_tree(dir, { "lib/deep/naïve/café.rb" => "# café\n" })

      paths = hasher.manifest(dir).map(&:path)

      assert_equal [ "lib/deep/naïve/café.rb" ], paths
      assert paths.all? { |path| path.encoding == Encoding::UTF_8 && path.valid_encoding? }
      refute_includes paths.first, "\\"
    end
  end

  def test_a_manifest_is_a_frozen_list_of_frozen_values
    with_directory do |dir|
      write_tree(dir, FIXTURE)

      manifest = hasher.manifest(dir)

      assert_predicate manifest, :frozen?
      assert_equal %i[path mode sha256], RubyCdk::Assets::Hasher::Entry.members
      assert manifest.all? { |entry| entry.frozen? }
    end
  end

  def test_the_hash_is_64_lower_case_hex_characters_and_the_digest_of_the_canonical_text
    with_directory do |dir|
      write_tree(dir, FIXTURE)

      hash = hasher.asset_hash(dir)

      assert_match(/\A[0-9a-f]{64}\z/, hash)
      assert_equal Digest::SHA256.hexdigest(hasher.canonical(hasher.manifest(dir))), hash
      assert_equal hasher.manifest_hash(hasher.manifest(dir)), hasher.asset_hash(dir)
    end
  end

  def test_an_empty_directory_hashes_to_the_digest_of_nothing
    with_directory do |dir|
      assert_equal [], hasher.manifest(dir)
      assert_equal "", hasher.canonical([])
      assert_equal "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hasher.asset_hash(dir)
    end
  end

  def test_the_hash_ignores_modification_times
    with_directory do |dir|
      write_tree(dir, FIXTURE)
      before = hasher.asset_hash(dir)

      files = FIXTURE.keys.map { |path| File.join(dir, path) }
      files.each_with_index { |file, index| File.utime(Time.at(1_000_000_000 + (index * 86_400)), Time.at(2_000_000_000), file) }
      assert_equal before, hasher.asset_hash(dir)

      files.each_with_index { |file, index| File.utime(Time.at(946_684_800 - (index * 3_600)), Time.at(946_684_800), file) }
      assert_equal before, hasher.asset_hash(dir)
    end
  end

  def test_the_hash_ignores_the_order_files_were_created_in
    with_directory do |first|
      write_tree(first, FIXTURE.merge("lib/deep/other.txt" => "other"))
      with_directory do |second|
        write_tree(second, FIXTURE.merge("lib/deep/other.txt" => "other").reverse_each.to_h)

        assert_equal hasher.asset_hash(first), hasher.asset_hash(second)
      end
    end
  end

  def test_the_hash_ignores_every_permission_bit_except_the_executable_bit_of_the_owner
    # Every mode keeps the owner's read bit, or the file could not be read at all.
    groups = {
      "0644" => [ 0o400, 0o444, 0o600, 0o640, 0o644, 0o664, 0o666, 0o645, 0o454 ],
      "0755" => [ 0o500, 0o700, 0o711, 0o750, 0o755, 0o777, 0o505 ]
    }
    hashes = Hash.new { |hash, mode| hash[mode] = [] }
    with_directory do |dir|
      file = File.join(dir, "file.txt")
      File.write(file, "content")

      groups.each do |mode, permissions|
        permissions.each do |permission|
          File.chmod(permission, file)
          entry = hasher.manifest(dir).first

          assert_equal mode, entry.mode, format("chmod %04o", permission)
          hashes[mode] << hasher.asset_hash(dir)
        end
      end
    end

    assert_equal 1, hashes["0644"].uniq.size
    assert_equal 1, hashes["0755"].uniq.size
    refute_equal hashes["0644"].first, hashes["0755"].first
  end

  def test_the_hash_is_the_same_under_another_umask
    under_umask(0o022) do
      with_directory do |loose|
        write_tree(loose, FIXTURE)
        File.chmod(0o755, File.join(loose, "bin/run"))
        under_umask(0o077) do
          with_directory do |strict|
            write_tree(strict, FIXTURE)
            File.chmod(0o700, File.join(strict, "bin/run"))

            assert_operator File.stat(File.join(strict, "app.rb")).mode & 0o777, :<, File.stat(File.join(loose, "app.rb")).mode & 0o777
            assert_equal hasher.asset_hash(loose), hasher.asset_hash(strict)
          end
        end
      end
    end
  end

  def test_changing_one_byte_changes_the_hash
    with_directory do |dir|
      write_tree(dir, FIXTURE)
      before = hasher.asset_hash(dir)

      File.write(File.join(dir, "app.rb"), File.binread(File.join(dir, "app.rb")) + ".")

      refute_equal before, hasher.asset_hash(dir)
    end
  end

  def test_line_endings_are_content
    with_directory do |lf|
      write_tree(lf, { "message.txt" => "hello word\nthis a new line!\n" })
      with_directory do |crlf|
        write_tree(crlf, { "message.txt" => "hello word\r\nthis a new line!\r\n" })

        refute_equal hasher.asset_hash(lf), hasher.asset_hash(crlf)
      end
    end
  end

  def test_the_same_files_moved_to_another_directory_keep_the_hash
    with_directory do |here|
      write_tree(here, FIXTURE)
      before = hasher.asset_hash(here)
      with_directory do |there|
        FIXTURE.keys.map { |path| path.split("/").first }.uniq.each { |entry| FileUtils.mv(File.join(here, entry), File.join(there, entry)) }

        assert_equal [], Dir.children(here)
        assert_equal before, hasher.asset_hash(there)
      end
    end
  end

  # --- what is refused

  def test_a_symbolic_link_to_a_file_is_refused
    with_directory do |dir|
      File.write(File.join(dir, "target.txt"), "target-content")
      File.symlink("target.txt", File.join(dir, "link.txt"))

      error = assert_raises(RubyCdk::Assets::SymlinkError) { hasher.manifest(dir) }

      assert_match(/link\.txt/, error.message)
      assert_raises(RubyCdk::Assets::SymlinkError) { hasher.asset_hash(dir) }
    end
  end

  def test_a_symbolic_link_to_a_directory_is_refused
    with_directory do |dir|
      Dir.mkdir(File.join(dir, "real"))
      File.write(File.join(dir, "real/file.txt"), "x")
      File.symlink("real", File.join(dir, "linked"))

      error = assert_raises(RubyCdk::Assets::SymlinkError) { hasher.manifest(dir) }

      assert_match(/linked/, error.message)
    end
  end

  def test_a_dangling_symbolic_link_is_refused
    with_directory do |dir|
      File.symlink("/nonexistent/path/to/nowhere", File.join(dir, "dangling"))

      error = assert_raises(RubyCdk::Assets::SymlinkError) { hasher.manifest(dir) }

      assert_match(/dangling/, error.message)
    end
  end

  def test_a_symbolic_link_in_a_subdirectory_is_refused
    with_directory do |dir|
      write_tree(dir, { "subdir/target.txt" => "hello" })
      File.symlink("../subdir/target.txt", File.join(dir, "subdir/rel-link.txt"))

      error = assert_raises(RubyCdk::Assets::SymlinkError) { hasher.manifest(dir) }

      assert_match(%r{subdir/rel-link\.txt}, error.message)
    end
  end

  def test_a_symbolic_link_that_is_excluded_is_not_looked_at
    with_directory do |dir|
      write_tree(dir, FIXTURE)
      File.chmod(0o755, File.join(dir, "bin/run"))
      File.symlink("/nonexistent/path/to/nowhere", File.join(dir, "skip-me"))

      assert_equal FIXTURE_HASH, hasher.asset_hash(dir, exclude: [ "skip-me" ])
    end
  end

  def test_a_file_that_is_not_a_regular_file_is_refused
    with_directory do |dir|
      write_tree(dir, { "app.rb" => "app" })
      File.mkfifo(File.join(dir, "pipe"))

      error = assert_raises(RubyCdk::Assets::UnsupportedEntryError) { hasher.manifest(dir) }

      assert_match(/pipe.*fifo/, error.message)
    end
  end

  def test_a_file_name_with_a_line_break_is_refused
    with_directory do |dir|
      File.write(File.join(dir, "a\n0644 b.rb"), "x")

      error = assert_raises(RubyCdk::Assets::UnsupportedEntryError) { hasher.manifest(dir) }

      assert_match(/line break/, error.message)
    end
  end

  def test_a_file_name_with_a_backslash_is_refused
    with_directory do |dir|
      # Legal on POSIX, but the zip would carry it verbatim, and readers that
      # take a backslash for a separator would not find the file where the
      # hash says it is.
      File.write(File.join(dir, "a\\b.rb"), "x")

      error = assert_raises(RubyCdk::Assets::UnsupportedEntryError) { hasher.manifest(dir) }

      assert_match(/backslash/, error.message)
      # The message shows the name through inspect, which doubles the backslash.
      assert_includes error.message, "a\\b.rb".inspect
    end
  end

  def test_an_unreadable_file_is_reported_as_its_own_error
    skip "root reads every file" if Process.euid.zero?

    with_directory do |dir|
      write_tree(dir, { "app.rb" => "app", "secret" => "s" })
      File.chmod(0o000, File.join(dir, "secret"))

      error = assert_raises(RubyCdk::Assets::SourceNotFoundError) { hasher.manifest(dir) }

      assert_match(/secret/, error.message)
      assert_match(/cannot be read/, error.message)
    end
  end

  def test_an_unlistable_directory_is_reported_as_its_own_error
    skip "root reads every directory" if Process.euid.zero?

    with_directory do |dir|
      write_tree(dir, { "app.rb" => "app" })
      Dir.mkdir(File.join(dir, "locked"))
      File.chmod(0o000, File.join(dir, "locked"))

      error = assert_raises(RubyCdk::Assets::SourceNotFoundError) { hasher.manifest(dir) }

      assert_match(/locked/, error.message)
      assert_match(/cannot be read/, error.message)
    end
  end

  def test_a_path_that_is_a_file_is_refused
    with_directory do |dir|
      file = File.join(dir, "file.txt")
      File.write(file, "x")

      error = assert_raises(RubyCdk::Assets::SourceNotFoundError) { hasher.manifest(file) }

      assert_match(/is not a directory/, error.message)
    end
  end

  def test_every_deliberate_error_is_a_ruby_cdk_error
    [ RubyCdk::Assets::SourceNotFoundError, RubyCdk::Assets::SymlinkError, RubyCdk::Assets::UnsupportedEntryError ].each do |klass|
      assert_operator klass, :<, RubyCdk::Error
    end
  end

  # --- excludes

  def test_the_default_excludes
    with_directory do |dir|
      write_tree(dir, {
        ".git/config" => "[core]", ".DS_Store" => "", "server.log" => "", "logs/debug.log" => "",
        ".gitignore" => "", "logger.rb" => "", "logs/keep.txt" => ""
      })

      assert_equal %w[.gitignore logger.rb logs/keep.txt], hasher.manifest(dir).map(&:path)
    end
  end

  def test_a_directory_is_excluded_whole_and_is_not_entered
    with_directory do |dir|
      write_tree(dir, { "app.rb" => "app", "vendor/cache/gems/x.gem" => "gem", "vendor/keep.txt" => "keep" })
      File.symlink("/nonexistent", File.join(dir, "vendor/cache/link"))

      assert_equal %w[app.rb vendor/keep.txt], hasher.manifest(dir, exclude: [ "vendor/cache" ]).map(&:path)
      assert_raises(RubyCdk::Assets::SymlinkError) { hasher.manifest(dir, exclude: [ "vendor/keep.txt" ]) }
    end
  end

  def test_custom_excludes_add_to_the_defaults
    with_directory do |dir|
      write_tree(dir, { "app.rb" => "app", "build/app.tmp" => "tmp", "notes.log" => "log" })

      assert_equal %w[app.rb], hasher.manifest(dir, exclude: [ "build" ]).map(&:path)
      assert_equal %w[app.rb], hasher.manifest(dir, exclude: [ "*.tmp" ]).map(&:path)
    end
  end

  def test_a_base_name_pattern_matches_at_every_depth_and_a_leading_dot
    with_directory do |dir|
      write_tree(dir, { "a/keep.rb" => "a", "a/tmp/x" => "x", "tmp/y" => "y", ".tmp" => "dot", "a/.tmp/x" => "x" })

      # Dot files are listed like any other file.
      assert_equal %w[.tmp a/.tmp/x a/keep.rb a/tmp/x tmp/y], hasher.manifest(dir).map(&:path)
      # A base name matches at every depth.
      assert_equal %w[.tmp a/.tmp/x a/keep.rb], hasher.manifest(dir, exclude: [ "tmp" ]).map(&:path)
      # `*` also matches a leading dot: ".tmp" is a "*tmp".
      assert_equal %w[a/keep.rb], hasher.manifest(dir, exclude: [ "*tmp" ]).map(&:path)
    end
  end

  def test_a_pattern_with_a_slash_matches_the_whole_relative_path
    with_directory do |dir|
      write_tree(dir, {
        "spec/a.json" => "a", "spec/fixtures/large/a.json" => "a", "spec/fixtures/large/deep/b.json" => "b",
        "x/node_modules/p/index.js" => "i", "y/node_modules/q/index.js" => "i"
      })

      # A `*` between slashes does not cross a directory boundary.
      assert_equal %w[spec/fixtures/large/a.json spec/fixtures/large/deep/b.json x/node_modules/p/index.js y/node_modules/q/index.js],
        hasher.manifest(dir, exclude: [ "spec/*.json" ]).map(&:path)
      # What sits directly inside a directory goes, the subdirectory with it.
      assert_equal %w[spec/a.json x/node_modules/p/index.js y/node_modules/q/index.js],
        hasher.manifest(dir, exclude: [ "spec/fixtures/large/*" ]).map(&:path)
      assert_equal %w[spec/a.json spec/fixtures/large/a.json spec/fixtures/large/deep/b.json],
        hasher.manifest(dir, exclude: [ "**/node_modules" ]).map(&:path)
      assert_equal %w[spec/fixtures/large/a.json spec/fixtures/large/deep/b.json x/node_modules/p/index.js y/node_modules/q/index.js],
        hasher.manifest(dir, exclude: [ "spec/{a,b}.json" ]).map(&:path)
      assert_equal %w[spec/a.json], hasher.manifest(dir, exclude: [ "spec/fixtures", "**/node_modules" ]).map(&:path)
    end
  end

  private

  def hasher
    RubyCdk::Assets::Hasher
  end

  def sha256(content)
    Digest::SHA256.hexdigest(content)
  end

  def with_directory(&block)
    Dir.mktmpdir("assets-hasher", &block)
  end

  def under_umask(mask)
    previous = File.umask(mask)
    yield
  ensure
    File.umask(previous)
  end

  # Writes a tree of "relative path" => content into dir, in the order given.
  def write_tree(dir, tree)
    tree.each do |path, content|
      file = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, content)
    end
  end

  def copy_tree(from, to)
    FileUtils.cp_r(File.join(from, "."), to)
  end
end
