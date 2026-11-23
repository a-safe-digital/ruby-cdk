# frozen_string_literal: true

require_relative "hasher"

module RubyCdk
  module Assets
    # Files changed between the moment an asset was hashed and the moment its
    # hash is checked again or its zip is built.
    class AssetChangedError < Error; end

    # One directory of files on its way to the asset bucket: where the files
    # are, what was left out, and the identity both derive from.
    #
    # The identity is the manifest hash (Hasher), and the object key is
    # "<manifest hash>.zip". It is a value: two records of the same files are
    # equal, wherever the files sit.
    Record = Data.define(:source_path, :exclude, :manifest, :manifest_hash)

    class Record
      # Hashes the directory now and returns its record.
      #
      # source_path: the directory, absolute or relative to the working
      # directory. The record keeps the absolute path.
      # exclude: the patterns Hasher.manifest takes.
      # expected_hash: the manifest hash recorded earlier, at synthesis. Given,
      # the directory must still hash to it, or AssetChangedError is raised:
      # a template that names the old key must not be served other files.
      #
      # Raises what Hasher.manifest raises.
      def self.build(source_path, exclude: [], expected_hash: nil)
        manifest = Hasher.manifest(source_path, exclude: exclude)
        hash = Hasher.manifest_hash(manifest)
        if expected_hash && expected_hash != hash
          raise AssetChangedError, "The asset at #{File.expand_path(source_path.to_s)} changed after it was hashed: " \
                                   "it now hashes to #{hash}, not to #{expected_hash}. Synthesize again."
        end

        new(source_path: File.expand_path(source_path.to_s), exclude: Array(exclude).map(&:dup).freeze,
          manifest:, manifest_hash: hash)
      end

      # "<manifest hash>.zip"
      def key
        "#{manifest_hash}.zip"
      end
    end
  end
end
