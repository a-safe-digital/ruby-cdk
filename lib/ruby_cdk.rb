# frozen_string_literal: true

require_relative "ruby_cdk/version"
require_relative "ruby_cdk/errors"
require_relative "ruby_cdk/lazy"
require_relative "ruby_cdk/fn"
require_relative "ruby_cdk/env"
require_relative "ruby_cdk/assets"
require_relative "ruby_cdk/core"
require_relative "ruby_cdk/cfn"

# Infrastructure as code in pure Ruby, in the style of the AWS CDK.
#
# Requiring this file loads the synthesis path only. No AWS SDK is loaded until a
# deploy command asks for it, so `synth` needs no credentials and starts fast.
module RubyCdk
end
