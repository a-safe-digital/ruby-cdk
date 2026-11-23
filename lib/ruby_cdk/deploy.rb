# frozen_string_literal: true

require_relative "deploy/ports"
require_relative "deploy/deployer"

module RubyCdk
  # The deploy engine. Loaded by the commands that change something in AWS,
  # never by `synth`.
  module Deploy
  end
end
