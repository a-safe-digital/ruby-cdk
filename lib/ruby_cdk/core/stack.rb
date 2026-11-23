# frozen_string_literal: true

require_relative "../assets/builder"

module RubyCdk
  # One template. Built from a block evaluated in its own context, or from a
  # subclass that overrides build.
  class Stack < Construct
    attr_reader :stack_name, :termination_protection

    def initialize(scope, id, env: nil, description: nil, tags: {}, stateful_default: nil, termination_protection: false, &block)
      raise NotImplementedError, "Wave 1, track A"
    end

    def parameter(id, type:, default: nil, description: nil, allowed_values: nil, no_echo: false)
      raise NotImplementedError, "Wave 1, track A"
    end

    def output(id, value:, description: nil, export: false, condition: nil)
      raise NotImplementedError, "Wave 1, track A"
    end

    # An output whose Export name is export_name(id).
    def export(id, value:, description: nil)
      raise NotImplementedError, "Wave 1, track A"
    end

    # "#{stack_name}-#{id}"
    def export_name(id)
      raise NotImplementedError, "Wave 1, track A"
    end

    def mapping(id, hash)
      raise NotImplementedError, "Wave 1, track A"
    end

    def condition(id, fn)
      raise NotImplementedError, "Wave 1, track A"
    end

    def asset
      raise NotImplementedError, "Wave 1, track A"
    end

    # "#{stack_name}-#{suffix}-<8 hex>": stable across deploys, different in
    # another account or region. Needs a concrete env.
    def unique_name(suffix = nil, max_length: 64)
      raise NotImplementedError, "Wave 1, track A"
    end

    def add_dependency(stack)
      raise NotImplementedError, "Wave 1, track A"
    end

    # Runs every phase except write and returns the template as a Hash.
    def to_template
      raise NotImplementedError, "Wave 1, track A"
    end
  end
end
