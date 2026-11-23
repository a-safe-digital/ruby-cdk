# frozen_string_literal: true

module RubyCdk
  # A concrete target: an account and a region.
  class Env
    ACCOUNT_PATTERN = /\A\d{12}\z/
    REGION_PATTERN = /\A[a-z]{2}(-[a-z0-9]+)+-\d\z/

    attr_reader :account, :region

    def initialize(account:, region:)
      unless ACCOUNT_PATTERN.match?(account.to_s)
        raise ArgumentError, "account must be a 12-digit account ID, got #{account.inspect}"
      end

      unless REGION_PATTERN.match?(region.to_s)
        raise ArgumentError, "region must look like eu-west-1, got #{region.inspect}"
      end

      @account = account.to_s.freeze
      @region = region.to_s.freeze
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
