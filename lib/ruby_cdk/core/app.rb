# frozen_string_literal: true

module RubyCdk
  # The root of the tree.
  class App < Construct
    attr_reader :env, :out_dir, :stacks, :stack_name_prefix, :stateful_default

    # The App the command line runs. Errors if there is none, or several.
    def self.current
      raise NotImplementedError, "Wave 1, track A"
    end

    # Requires the app file and returns the one App it created.
    def self.build!(app_file:)
      raise NotImplementedError, "Wave 1, track A"
    end

    def initialize(env: nil, out_dir: "cdk.out", stack_name_prefix: nil, stateful_default: :retain_except_on_create, &block)
      raise NotImplementedError, "Wave 1, track A"
    end

    # Runs every phase on every stack and writes the templates and the manifest.
    def synth
      raise NotImplementedError, "Wave 1, track A"
    end
  end
end
