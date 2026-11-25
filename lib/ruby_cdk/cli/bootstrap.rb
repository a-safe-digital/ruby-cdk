# frozen_string_literal: true

require_relative "failure"

module RubyCdk
  module Cli
    # `bootstrap`: the tool's asset bucket, deployed as the `ruby-cdk-bootstrap`
    # stack through the bootstrap component (architecture section 8). There is
    # no app file: the component builds the stack in an App of its own, with the
    # env the command resolves. One stack, so deploy's selection does not apply.
    #
    # The target is who the credentials say (architecture section 13), printed
    # by the engine before anything happens; --account given must be that
    # account, checked here before anything is built, because an env is made of
    # the resolved identity and the engine's own check would never fire.
    module Bootstrap
      # names are not taken: bootstrap is one stack.
      def self.run(session)
        region = session.options.region || session.aws.region(profile: session.options.profile, region: nil)
        clients = session.aws.clients(profile: session.options.profile, region: region)
        identity = session.identity(clients)
        assert_account(session, identity)

        app = RubyCdk::App.new(env: RubyCdk::Env.new(account: identity.account, region: region))
        options = Deploy::DeployOptions.new(yes: !!session.options.yes, account: session.options.account,
          profile: session.options.profile)

        result = RubyCdk::Bootstrap.run(app:, clients:, output: session.output,
          deployer_arn: session.options.deployer, options:)
        print_json(session, result) if session.options.json
        result.exit_code
      end

      # For --json, the one object on standard out, in the shape a deploy's
      # records have, and nothing else there.
      def self.print_json(session, result)
        session.io.result("#{JSON.generate(
          "name" => result.stack_name,
          "stack_id" => result.stack_id,
          "outcome" => result.outcome.to_s,
          "exit_code" => result.exit_code,
          "changes" => result.changes.map(&:to_h),
          "outputs" => result.outputs
        )}\n")
      end

      # --account is an assertion (architecture section 13): given, it must be
      # the account the credentials resolve to, which is the account the
      # bootstrap stack's env names. The engine would never see a mismatch,
      # because the env is built from the identity; so the command checks.
      def self.assert_account(session, identity)
        wanted = session.options.account
        return unless wanted && wanted.to_s != identity.account.to_s

        Kernel.raise Usage.new("--account #{wanted} was given, but the credentials are for account #{identity.account}. " \
          "Bootstrap deploys into the account the credentials name, and the asset bucket's name is made of it. " \
          "Nothing was created.",
          next_step: "Run `ruby-cdk bootstrap` again without --account, or with --account #{identity.account} " \
            "if that is the account you mean (--profile NAME selects the credentials).")
      end
    end
  end
end
