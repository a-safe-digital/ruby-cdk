# frozen_string_literal: true

require_relative "../lazy"

module RubyCdk
  module Assets
    # A zipped directory. Its identity is the hash of its manifest, which is
    # also its object key. Reached through `stack.asset.zip`.
    class Zip
      attr_reader :hash, :key

      def initialize(hash:, key:)
        @hash = hash
        @key = key
      end

      # The asset bucket of the stack's env.
      def bucket
        raise NotImplementedError, "Wave 3"
      end

      # For a Lambda `code`: {"S3Bucket" => ..., "S3Key" => ...}.
      def s3_location
        { "S3Bucket" => bucket, "S3Key" => key }
      end
    end

    # Creates file assets for a stack.
    class Builder
      attr_reader :stack

      def initialize(stack)
        @stack = stack
      end

      # Returns a Lazy that resolves to an Assets::Zip.
      def zip(path, exclude: [])
        raise NotImplementedError, "Wave 3"
      end
    end
  end
end
