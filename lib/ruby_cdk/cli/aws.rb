# frozen_string_literal: true

module RubyCdk
  module Cli
    # The one place in the command line that asks the adapters for anything.
    #
    # It is an object, so that a test gives the command line another one and no
    # client is ever built. Everything the command line knows about a region or
    # a client it learns from here: resolving the region of a stack that names
    # none (architecture section 13), and the clients of a region.
    module Aws
      # The region a client is built for when neither --region nor the stack's
      # env names one: what the adapters read from the environment and from the
      # profile's configuration. Raises RubyCdk::PreconditionError when nothing does.
      def self.region(profile:, region:)
        adapters
        RubyCdk::Deploy::Sdk.resolve_region(profile: profile, region: region)
      end

      # The CloudFormation client and the object store of a region.
      def self.clients(profile:, region:)
        adapters
        RubyCdk::Deploy::Sdk.clients(profile: profile, region: region)
      end

      # The adapters are loaded here, and only when a command needs a client,
      # so that `version` and `synth` never load the AWS SDK (architecture
      # principle 10).
      def self.adapters
        require_relative "../deploy/sdk_adapters"
      end
      private_class_method :adapters
    end
  end
end
