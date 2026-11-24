# frozen_string_literal: true

require_relative "sources/compiler"
require_relative "sources/download"
require_relative "sources/provider_schemas"
require_relative "sources/regions"
require_relative "sources/resource_specification"
require_relative "sources/update"

module RubyCdk
  module Schema
    # Builds data/spec from the two sources AWS publishes. Only `rake spec:update` loads
    # this file: it needs the network, and synthesis never does.
    #
    #   RubyCdk::Schema::Sources.update(region: "us-east-1", dir: "data/spec")
    module Sources
      private_constant :ProviderType, :SpecificationType
    end
  end
end
