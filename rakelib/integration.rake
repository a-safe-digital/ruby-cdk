# frozen_string_literal: true

require "rbconfig"

desc "Real CloudFormation in the sandbox under WF-5. It needs the three variables of the " \
     "protocol in the environment (RUBY_CDK_AWS_PROFILE, RUBY_CDK_ALLOW_ACCOUNT, RUBY_CDK_ALLOW_REGION), " \
     "which never enter the repository, and the owner's approval for the wave. " \
     "It is never part of the default task, and nothing else loads the AWS tests"
task :integration do
  missing = %w[RUBY_CDK_AWS_PROFILE RUBY_CDK_ALLOW_ACCOUNT RUBY_CDK_ALLOW_REGION].select { |name| ENV[name].to_s.strip.empty? }
  unless missing.empty?
    abort "integration: #{missing.join(", ")} must be set in the environment, and none of them may be blank. " \
      "They name the sandbox the owner approved for this wave, and they never enter the repository (WF-5). " \
      "Without them the run refuses before anything is loaded that could reach AWS."
  end

  sh RbConfig.ruby, "-Ilib", "-Itest", File.expand_path("../test/integration/aws/run.rb", __dir__)
end
