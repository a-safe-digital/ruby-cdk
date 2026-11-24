# frozen_string_literal: true

require_relative "ruby_cdk/version"
require_relative "ruby_cdk/values"
require_relative "ruby_cdk/core"
require_relative "ruby_cdk/cfn"
require_relative "ruby_cdk/synth"
require_relative "ruby_cdk/schema"
require_relative "ruby_cdk/schema/validator"
require_relative "ruby_cdk/assets"

# Infrastructure as code in pure Ruby, in the style of the AWS CDK.
#
# Requiring this file loads the synthesis path only. No AWS SDK is loaded until a
# deploy command asks for it, so `synth` needs no credentials and starts fast.
#
# This is also where the synthesis path is put together. The components know
# each other only as their rows in the component map say, and a lower one never
# names a higher one, so the hooks that join them are registered here.
module RubyCdk
end

# The assets of a stack, for its entry in the manifest: the hashes of what it
# resolved. Only the assets component can list them, and only the pipeline
# writes the manifest; neither may name the other.
RubyCdk::Synth.register_entry_fact(RubyCdk::Synth::Manifest::ASSETS_KEY) do |stack, _template|
  stack.asset_hashes.map { |hash| "sha256:#{hash}" }
end

# Which model was consulted, for the manifest. It moves only when the model does.
RubyCdk::Synth.register_manifest_fact(RubyCdk::Synth::Manifest::SCHEMA_VERSION_KEY) do
  RubyCdk::Schema.schema_version
end

# What CloudFormation would reject, found before it leaves the machine: the
# normalizer and the rules, registered with the pipeline here, where two
# components can be joined without either naming the other. V2 and V13 stay
# out of the pipeline's list: the tree reports them at synth already. Warnings
# wait for the pipeline's separate warnings list; the validators answer errors.
RubyCdk::Synth.register_normalizer(RubyCdk::Validation.normalizers.first)
RubyCdk::Validation.validators(
  stateful_types: RubyCdk::Core::Stateful::RETAINED_TYPES + RubyCdk::Core::Stateful::SNAPSHOT_TYPES
).each { |validator| RubyCdk::Synth.register_validator(validator) }
