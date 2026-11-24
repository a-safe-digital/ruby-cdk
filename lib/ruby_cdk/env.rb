# frozen_string_literal: true

module RubyCdk
  # A concrete target: an account and a region.
  class Env
    ACCOUNT_PATTERN = /\A\d{12}\z/
    REGION_PATTERN = /\A[a-z]{2}(-[a-z0-9]+)+-\d\z/

    attr_reader :account, :region

    def initialize(account:, region:)
      # The account must be a String, as the CDK refuses a non-string one
      # ("Account id of stack environment must be a 'string'", core/lib/stack.ts
      # parseEnvironment). An Integer's to_s would look fine and slip through.
      unless account.is_a?(String) && ACCOUNT_PATTERN.match?(account)
        raise ArgumentError, "account must be a 12-digit account ID as a String, got #{account.inspect}"
      end

      unless region.is_a?(String) && REGION_PATTERN.match?(region)
        raise ArgumentError, "region must look like eu-west-1, got #{region.inspect}"
      end

      @account = account.freeze
      @region = region.freeze
      freeze
    end

    def name
      "#{account}/#{region}"
    end
    alias to_s name

    def ==(other)
      other.is_a?(Env) && other.account == account && other.region == region
    end
    alias eql? ==

    def hash
      [ self.class, account, region ].hash
    end
  end
end
