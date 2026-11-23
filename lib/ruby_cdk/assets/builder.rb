# frozen_string_literal: true

require_relative "../lazy"
require_relative "record"

module RubyCdk
  module Assets
    # A directory of files as an asset of a stack (architecture §8).
    #
    # Its identity is the manifest hash of its files (Hasher), which is also its
    # object key: the same files give the same asset on every machine, whatever
    # their path, their order or their timestamps. Reached through `stack.asset`.
    #
    # Every accessor answers a Lazy: the files are read when the stack is
    # resolved, not when the asset is declared, so that what is uploaded is what
    # the files are at synthesis.
    class Zip
      attr_reader :stack, :source_path, :exclude

      def initialize(stack, source_path, exclude: [])
        @stack = stack
        @source_path = source_path
        @exclude = Array(exclude).dup.freeze
        @record = nil
      end

      # True once the files were read and hashed.
      def resolved?
        !@record.nil?
      end

      # The record of the files: read and hashed on first use, then kept.
      # Raises what Record.build raises.
      def record
        @record ||= Record.build(@source_path, exclude: @exclude)
      end

      # The identity of the asset: its manifest hash.
      #
      # Not named hash: Object#hash must answer an Integer, and an asset whose
      # hash is a String could not be a Hash key or sit in a Set.
      def asset_hash
        Lazy.new { record.manifest_hash }
      end

      # "<manifest hash>.zip"
      def key
        Lazy.new { record.key }
      end

      # The asset bucket of the stack's environment.
      def bucket
        Lazy.new { bucket_name }
      end

      # For a Lambda `code`: {"S3Bucket" => ..., "S3Key" => ...}.
      def s3_location
        Lazy.new { { "S3Bucket" => bucket_name, "S3Key" => record.key } }
      end

      private

      def bucket_name
        Assets.bucket_name(@stack.env.account, @stack.env.region)
      end
    end

    # Creates the file assets of a stack. Reached through `stack.asset`.
    class Builder
      attr_reader :stack

      def initialize(stack)
        @stack = stack
        @zips = []
      end

      # A directory of files as an asset. Nothing is read yet: the directory is
      # walked and hashed when the stack is resolved (architecture §8).
      #
      # path: the directory, relative to the current one, so write it from
      # __dir__ in the app file to be independent of where the command runs.
      # exclude: patterns in addition to Hasher::DEFAULT_EXCLUDES.
      def zip(path, exclude: [])
        unless @stack.env
          raise UsageError, "#{@stack.path}: an asset needs a concrete env, because the name of its bucket is made " \
            "of the account and the region. Give the Stack or its App env: RubyCdk::Env.new(account:, region:)"
        end

        zip = Zip.new(@stack, path, exclude:)
        @zips << zip
        zip
      end

      # The manifest hashes of the assets that were resolved, in the order they
      # were declared and without a repeat. Synthesis writes them to the manifest.
      def hashes
        @zips.select(&:resolved?).map { |zip| zip.record.manifest_hash }.uniq
      end

      # The records of the assets that were resolved, one per distinct key: what
      # the deploy step uploads.
      def records
        @zips.select(&:resolved?).map(&:record).uniq(&:key)
      end
    end
  end
end
