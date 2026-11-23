# frozen_string_literal: true

require "digest"
require_relative "../errors"

module RubyCdk
  module Assets
    # The path given as an asset is not a directory: empty, missing, or a file.
    class SourceNotFoundError < Error; end

    # A symbolic link sits inside an asset directory.
    class SymlinkError < Error; end

    # Something under an asset directory that cannot be hashed and zipped as it
    # is: a file that is not a regular file, or a name that would not survive.
    class UnsupportedEntryError < Error; end

    # The content hash of a directory of files, which is the identity of an
    # asset (D-008).
    #
    # The manifest lists every file under the directory, sorted by relative
    # path, with the mode git would store for it and the SHA-256 of its bytes.
    # The hash is the SHA-256 of that manifest written as one line per file,
    # "<mode> <relative path> <content hash>", each line followed by a newline.
    #
    # Two machines hash the same files the same way whatever their umask or
    # modification times: only the owner's executable bit of the mode is kept,
    # and no timestamp is read at all.
    class Hasher
      Entry = Data.define(:path, :mode, :sha256)

      # Excluded unless the caller says otherwise.
      DEFAULT_EXCLUDES = %w[.git .DS_Store *.log].freeze

      EXECUTABLE = "0755"
      PLAIN = "0644"

      # `*` also matches a leading dot and `{a,b}` is allowed. In a pattern
      # that contains a slash, `*` does not cross a directory boundary.
      NAME_FLAGS = File::FNM_DOTMATCH | File::FNM_EXTGLOB
      PATH_FLAGS = File::FNM_DOTMATCH | File::FNM_EXTGLOB | File::FNM_PATHNAME

      class << self
        # Every file under source_path, sorted by relative path (forward
        # slashes, UTF-8). An excluded file is not listed and an excluded
        # directory is not entered.
        #
        # exclude: patterns in addition to DEFAULT_EXCLUDES. A pattern without
        # a slash is matched against the base name of every file and directory;
        # a pattern with a slash, against the whole relative path.
        #
        # Raises SourceNotFoundError when the path is empty or is not a
        # directory, SymlinkError for a symbolic link that is not excluded, and
        # UnsupportedEntryError for anything else that is not a regular file.
        def manifest(source_path, exclude: [])
          entries = []
          walk(File.expand_path(usable(source_path)), "", DEFAULT_EXCLUDES + Array(exclude), entries)
          entries.sort_by(&:path).freeze
        end

        # The text the hash digests: one "<mode> <relative path> <content hash>"
        # line per file, in manifest order, each ended by a newline.
        def canonical(entries)
          entries.map { |entry| "#{entry.mode} #{entry.path} #{entry.sha256}\n" }.join
        end

        # The SHA-256 of canonical(entries), as 64 lower-case hex characters.
        def manifest_hash(entries)
          Digest::SHA256.hexdigest(canonical(entries))
        end

        # The manifest hash of the directory. The same files in another
        # directory, created in another order or with other timestamps, give
        # the same hash.
        def hash(source_path, exclude: [])
          manifest_hash(manifest(source_path, exclude: exclude))
        end

        private

        def usable(source_path)
          path = source_path.to_s
          raise SourceNotFoundError, "Asset path cannot be empty" if path.strip.empty?
          return path if File.directory?(path)

          raise SourceNotFoundError, "Cannot find asset directory at #{path}" unless File.exist?(path)

          raise SourceNotFoundError, "Asset path is not a directory: #{path}"
        end

        def walk(directory, prefix, patterns, entries)
          Dir.children(directory).sort.each do |child|
            name = child.dup.force_encoding(Encoding::UTF_8)
            relative = prefix.empty? ? name : "#{prefix}/#{name}"
            next if excluded?(relative, patterns)

            path = File.join(directory, name)
            stat = File.lstat(path)
            if stat.symlink?
              raise SymlinkError, "Symbolic links are not allowed in an asset: #{relative} -> #{File.readlink(path)}. " \
                                  "Copy the file instead."
            end
            check_name(relative)

            if stat.directory?
              walk(path, relative, patterns, entries)
            elsif stat.file?
              entries << Entry.new(path: relative, mode: mode_for(stat), sha256: Digest::SHA256.file(path).hexdigest)
            else
              raise UnsupportedEntryError, "#{relative} is a #{stat.ftype}, not a regular file, so it cannot be in an asset"
            end
          end
        end

        def excluded?(relative, patterns)
          base = File.basename(relative)
          patterns.any? do |pattern|
            pattern.include?("/") ? File.fnmatch?(pattern, relative, PATH_FLAGS) : File.fnmatch?(pattern, base, NAME_FLAGS)
          end
        end

        # A line break would split one file into two lines of the canonical
        # text, and the zip entry name of a file must be valid UTF-8.
        def check_name(relative)
          if relative.include?("\n")
            raise UnsupportedEntryError, "A file name with a line break cannot be in an asset: #{relative.inspect}"
          end
          return if relative.valid_encoding?

          raise UnsupportedEntryError, "A file name that is not valid UTF-8 cannot be in an asset: #{relative.inspect}"
        end

        # The way git stores a mode: 0755 when the owner may execute the file,
        # 0644 for everything else. No other permission bit is kept.
        def mode_for(stat)
          (stat.mode & 0o100).zero? ? PLAIN : EXECUTABLE
        end
      end
    end
  end
end
