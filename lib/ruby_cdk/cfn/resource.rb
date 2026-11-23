# frozen_string_literal: true

require_relative "../core/construct"

module RubyCdk
  module Cfn
    # L1: a direct mapping to a CloudFormation resource.
    class Resource < Construct
      attr_reader :type, :logical_id, :properties

      def initialize(scope, id, type:, properties: nil, depends_on: [], condition: nil, deletion_policy: nil, update_replace_policy: nil, metadata: {}, **opts)
        raise NotImplementedError, "Wave 1, track A"
      end
    end
  end
end
