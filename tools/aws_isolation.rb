# frozen_string_literal: true

# Removes every way a test process could reach a real AWS account.
# `rake test` calls scrub! before it starts the suite, and test_helper does it again.
module Tools
  module AwsIsolation
    SCRUBBED_PREFIXES = %w[AWS_ RUBY_CDK_].freeze

    # Set after the scrub, so that nothing is found even if a profile is named.
    OVERRIDES = {
      "AWS_CONFIG_FILE" => "/dev/null",
      "AWS_SHARED_CREDENTIALS_FILE" => "/dev/null",
      "AWS_EC2_METADATA_DISABLED" => "true",
      "AWS_SDK_CONFIG_OPT_OUT" => "1"
    }.freeze

    module_function

    # A copy of env without anything that names an account, and with the overrides applied.
    def scrubbed_env(env = ENV)
      kept = env.reject { |key, _| SCRUBBED_PREFIXES.any? { |prefix| key.start_with?(prefix) } }
      kept.merge(OVERRIDES)
    end

    # Replaces the contents of env in place. Returns env.
    def scrub!(env = ENV)
      env.replace(scrubbed_env(env))
    end

    # True when env carries no AWS credential source and the metadata service is off.
    def scrubbed?(env = ENV)
      OVERRIDES.all? { |key, value| env[key] == value } &&
        env.keys.none? { |key| key.start_with?("AWS_") && !OVERRIDES.key?(key) } &&
        env.keys.none? { |key| key.start_with?("RUBY_CDK_") }
    end
  end
end
