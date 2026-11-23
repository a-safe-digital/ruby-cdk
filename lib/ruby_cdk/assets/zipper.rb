# frozen_string_literal: true

require "digest"
require "zip"
require_relative "../errors"
require_relative "record"

module RubyCdk
  module Assets
    # Builds the zip of a record. The same record always gives the same bytes.
    #
    # What goes into the archive, and nothing else:
    #
    # - one entry per file of the record's manifest, in manifest order, named
    #   by its relative path; no directory entries;
    # - deflate at COMPRESSION_LEVEL, the whole file fed to zlib in one piece;
    # - the mode 0644 or 0755 of the manifest in the external attributes;
    # - FIXED_TIME on every entry, and no extra field: timestamps are not
    #   written with sub-second or time-zone precision anywhere;
    # - no comment, on an entry or on the archive.
    #
    # A file whose content no longer matches its manifest entry is never
    # packed: AssetChangedError is raised instead.
    #
    # Byte for byte, the result depends on the versions of rubyzip and zlib,
    # and on rubyzip's `unicode_names` setting staying off (it would change one
    # byte: the version that made the archive). Nothing relies on the bytes:
    # an asset is identified by its manifest hash.
    class Zipper
      # The earliest date a zip entry can hold: 1980-01-01 00:00:00.
      FIXED_TIME = Time.utc(1980, 1, 1, 0, 0, 0).freeze

      # zlib's own default level, and the one yazl, the zip writer of the CDK
      # CLI, uses when it is given none.
      COMPRESSION_LEVEL = 6

      # General purpose bit 11: the entry name is UTF-8.
      UTF8_NAME = 0x800

      MODES = { "0644" => 0o644, "0755" => 0o755 }.freeze

      class << self
        # The zip of the record as a binary String.
        #
        # Raises AssetChangedError when a file of the manifest is gone or has
        # another content than when it was hashed.
        def build(record)
          # rubyzip is named with its leading "::": Assets::Zip, the asset, would
          # otherwise answer for Zip in this namespace.
          ::Zip::OutputStream.write_buffer do |output|
            record.manifest.each do |file|
              content = read(record, file)
              output.put_next_entry(entry_for(file, content.bytesize))
              output << content
            end
          end.string
        end

        # Writes the zip of the record to path, in binary mode. Returns the
        # number of bytes written.
        def write(record, path)
          File.binwrite(path, build(record))
        end

        private

        # The file as it was hashed, or AssetChangedError. It is never followed
        # through a symbolic link: the Hasher refuses those, so a link here is
        # a change too.
        def read(record, file)
          path = File.join(record.source_path, file.path)
          stat = File.lstat(path)
          unless stat.file?
            raise AssetChangedError, "#{path} is no longer a regular file. The asset changed after it was hashed. " \
                                     "Synthesize again."
          end

          content = File.binread(path)
          return content if Digest::SHA256.hexdigest(content) == file.sha256

          raise AssetChangedError, "#{path} changed after the asset was hashed. Synthesize again."
        rescue Errno::ENOENT
          raise AssetChangedError, "#{path} no longer exists. The asset changed after it was hashed. Synthesize again."
        end

        # Every field that could carry something time-, machine- or
        # configuration-derived is set here. `size` is one of them: left
        # unknown, rubyzip would put a zip64 extra field in every local header.
        def entry_for(file, size)
          entry = ::Zip::Entry.new(
            "", file.path,
            comment: "", size: size, compression_method: ::Zip::Entry::DEFLATED, compression_level: COMPRESSION_LEVEL,
            time: FIXED_TIME, extra: ::Zip::ExtraField.new
          )
          entry.fstype = ::Zip::FSTYPE_UNIX
          entry.unix_perms = MODES.fetch(file.mode)
          entry.internal_file_attributes = 0
          entry.gp_flags = UTF8_NAME
          entry
        end
      end
    end
  end
end
