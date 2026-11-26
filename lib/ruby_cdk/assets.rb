# frozen_string_literal: true

require "digest"
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
    #
    # The records are read before the owner is checked, so a stack without env
    # — which the account rule allows, and which cannot have resolved an asset
    # (Builder#zip refuses) — uploads nothing and reads nothing of its env.
    def self.publish(stack, store:, owner:)
      records = stack.asset.records
      return { uploaded: 0, skipped: 0 } if records.empty?

      account = stack.env.account.to_s
      unless owner.to_s == account
        # A precondition, not a usage error: the command line explains this one
        # to the user (the deploy stopped because the stack's env names another
        # account than the credentials carry), instead of reporting a bug.
        raise RubyCdk::PreconditionError, "publish was given owner #{owner.inspect}, but the bucket is named for the stack's " \
          "env account #{account.inspect}. Pass the resolved identity's account, and deploy a stack with an env " \
          "only with credentials of that account."
      end

      Uploader.new(store:, owner: account).upload_all(records, bucket: bucket_name(account, stack.env.region))
    end

    # Places a template in the bucket for a deploy by its URL (architecture
    # §8): CloudFormation takes at most 51,200 bytes of template in a request,
    # and above that the change set carries the address of the object instead
    # of the template. The key is templates/<stack name>/<sha256>.json, the
    # SHA-256 of the body, so the same template lands on the same key and the
    # uploader leaves a key that is already there alone — the second deploy of
    # the same template puts nothing. Answers the address of the object,
    # https://<bucket>.s3.<region>.amazonaws.com/<key>, the one the change set
    # carries as TemplateURL. That address is the commercial partition's shape,
    # written from the bucket's name and region, not read from the SDK: under
    # another partition, or with the endpoint overridden (the emulator
    # scenario), CloudFormation would not resolve it — the assumption is
    # recorded in architecture section 8.
    #
    # The bucket is the stack's own, named for its env as an asset bucket is,
    # and owner must be the stack's env account, as publish requires. The
    # command line wires this as the deployer's template publisher.
    def self.publish_template(stack, template, store:, owner:)
      env = stack.env
      unless env
        raise RubyCdk::PreconditionError,
          "The template of stack #{stack.stack_name} is too large to go in a request, so it is placed in the asset " \
          "bucket, and the bucket is named for the stack's env. Stack #{stack.stack_name} has no env, so there is no " \
          "bucket to place it in. Nothing was deployed.\n" \
          "Give the stack an env (account and region), or deploy a template that fits in a request."
      end

      account = env.account.to_s
      unless owner.to_s == account
        raise RubyCdk::PreconditionError, "publish_template was given owner #{owner.inspect}, but the bucket is named for the stack's " \
          "env account #{account.inspect}. Pass the resolved identity's account, and deploy a stack with an env " \
          "only with credentials of that account."
      end

      bucket = bucket_name(account, env.region)
      key = "templates/#{stack.stack_name}/#{Digest::SHA256.hexdigest(template)}.json"
      Uploader.new(store:, owner: account).upload_body(key, body: template, bucket: bucket)
      "https://#{bucket}.s3.#{env.region}.amazonaws.com/#{key}"
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
