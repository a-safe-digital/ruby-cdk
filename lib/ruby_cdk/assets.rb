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

    # Uploads, before any change set, what the deploy of a stack needs in its
    # bucket: the zips of the assets the stack resolved (architecture §8). The
    # command that deploys calls it after synthesis, in the same process, so the
    # records are the ones synthesis built.
    #
    # store is the object-store port. owner is the account that must own the
    # bucket: the resolved identity's, and it has to be the stack's env account,
    # because the bucket's name is made of that account and every check and
    # message names it. A stack with no asset uploads nothing and checks
    # nothing, which is what lets it deploy into an account that was never
    # bootstrapped.
    #
    # Answers { uploaded:, skipped: }. Raises what Uploader raises: a bucket
    # that is not ours stops the deploy before anything is looked up.
    def self.publish(stack, store:, owner:)
      account = stack.env.account.to_s
      unless owner.to_s == account
        raise ArgumentError, "publish was given owner #{owner.inspect}, but the bucket is named for the stack's " \
          "env account #{account.inspect}. Pass the resolved identity's account, and deploy a stack with an env " \
          "only with credentials of that account."
      end

      records = stack.asset.records
      return { uploaded: 0, skipped: 0 } if records.empty?

      Uploader.new(store:, owner: account).upload_all(records, bucket: bucket_name(account, stack.env.region))
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
