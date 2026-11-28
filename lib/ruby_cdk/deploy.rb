# frozen_string_literal: true

require_relative "errors"
require_relative "deploy/ports"
require_relative "deploy/errors"
require_relative "deploy/poller"
require_relative "deploy/capabilities"
require_relative "deploy/parameters"
require_relative "deploy/states"
require_relative "deploy/hotswap"
require_relative "deploy/deployer"
require_relative "deploy/output/human"
require_relative "deploy/output/quiet"
require_relative "deploy/output/json"

module RubyCdk
  # The deploy engine. Loaded by the commands that change something in AWS,
  # never by `synth`.
  #
  # This file is the entry of the `deploy` component: it loads the engine's
  # files and nothing else. The AWS SDK is reached only through
  # `ruby_cdk/deploy/sdk_adapters`, which a command loads on its own. The fakes
  # are `ruby_cdk/deploy/fakes`, which tests load on their own.
  module Deploy
  end
end
