# frozen_string_literal: true

require "rbconfig"

desc "Delete the integration stacks older than six hours that a crashed run left behind, " \
     "under WF-5 (docs/06-workflows.md). It needs the same three variables as `rake integration` " \
     "in the environment (RUBY_CDK_AWS_PROFILE, RUBY_CDK_ALLOW_ACCOUNT, RUBY_CDK_ALLOW_REGION), " \
     "which never enter the repository, and the owner's approval. RUBY_CDK_SWEEP_AFTER=<hours> " \
     "overrides the six hours. A stack matched by the prefix and the tag is deleted whole, through " \
     "CloudFormation; the physical IDs of everything left behind are reported, and nothing deletes " \
     "a physical resource by hand (WF-5 rule 6). It is never part of the default task"
task :sweep do
  missing = %w[RUBY_CDK_AWS_PROFILE RUBY_CDK_ALLOW_ACCOUNT RUBY_CDK_ALLOW_REGION].select { |name| ENV[name].to_s.strip.empty? }
  unless missing.empty?
    abort "sweep: #{missing.join(", ")} must be set in the environment, and none of them may be blank. " \
      "They name the sandbox the owner approved for this wave, and they never enter the repository (WF-5). " \
      "Without them the task refuses before anything is loaded that could reach AWS."
  end

  $LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
  require "ruby_cdk"
  require "ruby_cdk/deploy/sdk_adapters"
  require_relative "../test/integration/guard"
  require_relative "../test/integration/sweeper"

  # The guard says who and where, and refuses unless both are allowlisted; the
  # sweeper then works on the stacks of that account and region only.
  clients = RubyCdk::Deploy::Sdk.clients(profile: ENV.fetch("RUBY_CDK_AWS_PROFILE"),
    region: ENV.fetch("RUBY_CDK_ALLOW_REGION"))
  guard = Integration::Guard.new(port: clients.cfn)
  puts guard

  sweeper = Integration::Sweeper.new(client: clients.cfn)
  result = sweeper.run
  leftover = result.remaining.count(&:failure)
  abort "sweep: #{leftover} stack(s) left behind need a person; see the report above. " \
    "Nothing deletes a physical resource by hand (WF-5 rule 6)." if result.leftover?
  exit 0
end
