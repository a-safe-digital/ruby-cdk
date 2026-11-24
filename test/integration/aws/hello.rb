# frozen_string_literal: true

# The AWS side of the harness, for Wave 1's `examples/hello`. This file is
# loaded by `rake integration` and by nothing else; `rake test` never sees it.
# It is the only place in the repository that calls AWS, and it runs only under
# WF-5 (docs/06-workflows.md): the owner has approved the run, and the three
# variables of the protocol are in the environment. `rake integration` fails
# closed when any of the three is missing, before anything is loaded that could
# reach AWS.

require "ruby_cdk"
require_relative "../guard"
require_relative "../runner"
require "ruby_cdk/deploy/sdk_adapters"
require_relative "../../examples/hello/hello/stack"

module Integration
  module Aws
    module_function

    # The whole protocol, in the order WF-5 puts it: the guard says who and
    # where, the app is built with the guard's env and the integration prefix,
    # everything deploys, and the teardown runs however the deploys ended.
    def hello
      clients = RubyCdk::Deploy::Sdk.clients(profile: ENV.fetch("RUBY_CDK_AWS_PROFILE"),
        region: ENV.fetch("RUBY_CDK_ALLOW_REGION"))
      guard = Guard.new(port: clients.cfn)
      puts guard

      runner = Runner.new(client: clients.cfn)
      app = RubyCdk::App.new(**runner.app_options(guard.env)) do |integration|
        Hello::Stack.new(integration, "hello")
      end

      manifest = app.synth
      puts "integration: synthesized #{manifest.entries.length} stack(s) into #{manifest.out_dir}"

      identity = clients.cfn.resolve_identity
      deployer = RubyCdk::Deploy::Deployer.new(client: clients.cfn, store: clients.store,
        output: RubyCdk::Deploy::Output::Human.new)
      options = RubyCdk::Deploy::DeployOptions.new(yes: true, account: guard.allow_account, profile: guard.profile)

      begin
        manifest.entries.each do |entry|
          stack = app.stacks.find { |candidate| candidate.stack_name == entry.name }
          region = stack.env&.region || guard.allow_region
          raise RubyCdk::PreconditionError, "#{entry.name} would deploy to #{region}, and the run allowlists #{guard.allow_region}" unless region == guard.allow_region

          result = deployer.deploy(stack:, template: File.binread(File.join(manifest.out_dir, entry.template)),
            identity:, options:)
          puts "integration: #{entry.name}: #{result.outcome} (exit code #{result.exit_code})"
          raise RubyCdk::PreconditionError, "#{entry.name} ended with exit code #{result.exit_code}" unless result.exit_code.zero?
        end
      ensure
        # Teardown runs however the deploys ended, and the audit decides
        # whether the run may claim to have left nothing behind.
        app.stacks.each { |stack| runner.destroy(stack.stack_name) }
        runner.audit
      end
    end
  end
end
