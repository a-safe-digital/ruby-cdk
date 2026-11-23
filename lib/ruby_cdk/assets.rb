# frozen_string_literal: true

require_relative "deploy/ports"
require_relative "assets/builder"
require_relative "assets/hasher"
require_relative "assets/record"
require_relative "assets/zipper"
require_relative "assets/uploader"

module RubyCdk
  # File assets (architecture §8): a directory of files, hashed when the stack
  # is resolved, zipped and uploaded at deploy to the asset bucket of the
  # stack's environment, through the object-store port. The adapter behind that
  # port is the only code that knows S3.
  module Assets
    BUCKET_PREFIX = "ruby-cdk-assets-"

    # The name of the asset bucket of an account in a region. A function of
    # public facts, which is why every call on the bucket names its owner.
    def self.bucket_name(account, region)
      "#{BUCKET_PREFIX}#{account}-#{region}"
    end
  end

  # The tree's contract declares these; here are the implementations, in the
  # component that owns assets. The tree never names the assets component.
  class Stack
    # The builder of the stack's file assets.
    def asset
      @asset_builder ||= Assets::Builder.new(self)
    end

    # The manifest hashes of the assets this stack declared and resolved, in
    # the order they were declared and without a repeat. Synthesis writes them
    # to the manifest.
    def asset_hashes
      instance_variable_defined?(:@asset_builder) ? @asset_builder.hashes : []
    end
  end
end
