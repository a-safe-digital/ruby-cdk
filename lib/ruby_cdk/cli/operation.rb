# frozen_string_literal: true

require "json"
require_relative "failure"
require_relative "selection"

module RubyCdk
  module Cli
    # `deploy` and `destroy`: the same walk over the stacks selected, each one
    # through the engine, one at a time and stopping at the first that fails.
    #
    # The engine does the work and says what happens, through the output object
    # the session chose. This class decides which stacks, in which order, with
    # which region, and turns what came back into the exit code and, for
    # --json, one object per stack on standard out.
    class Operation
      attr_reader :session, :kind

      # kind is :deploy or :destroy.
      def initialize(session, kind:)
        @session = session
        @kind = kind
      end

      # names are the STACK words. Answers the exit code of the command
      # (architecture section 14): the first stack's that was not 0, else 0.
      def call(names)
        manifest = session.manifest
        session.say_synthesis_time
        selected = Selection.choose(session.stacks, names:, all: session.options.all, command: kind.to_s)
        entries = Selection.ordered(manifest.entries, selected: selected.map(&:stack_name),
          direction: kind == :deploy ? :up : :down, exclusively: session.options.exclusively)
        announce_dependencies(selected, entries)
        session.io.debug("#{kind}: #{entries.map(&:name).join(", ")}")

        # The options are read, and so checked, before any client is built: a
        # typo in one is a usage error and never a request.
        options = kind == :deploy ? session.deploy_options : session.destroy_options
        warn_hotswap if kind == :deploy && (options.hotswap || options.hotswap_fallback)

        entries.each_with_index do |entry, index|
          result = nil
          begin
            result = one(entry)
          rescue RubyCdk::Error => e
            record(entry.name, error: e)
            entries.drop(index + 1).each do |later|
              record(later.name, error: "not attempted: #{entry.name} before it ended with exit code #{Deploy.exit_code_for(e)}", code: nil)
            end
            raise
          end

          record(entry.name, result:)
          return result.exit_code unless result.exit_code.zero?
        end
        Cli::SUCCESS
      end

      private

      # What the command brings beside the stacks named: the CDK deploys the
      # dependencies of a named stack and destroys what depends on it, unless
      # --exclusively (packages/aws-cdk/lib/cli/cli.ts:800-839 in aws-cdk-cli,
      # expandUp and expandDown), and says so. --all was the answer, not an
      # announcement. Human output only.
      def announce_dependencies(selected, entries)
        return if session.options.all || session.options.exclusively

        extra = entries.map(&:name) - selected.map(&:stack_name)
        return if extra.empty?

        session.io.say("Including #{kind == :deploy ? "dependency" : "dependent"} stacks: #{extra.join(", ")}")
      end

      # One stack, from synthesis's output to the engine's answer.
      def one(entry)
        stack = session.stack(entry.name)
        region = session.region_of(stack)
        clients = session.clients(region:)
        session.io.debug("#{entry.name}: region #{region}#{session.region_source(stack)}")

        identity = session.identity(clients)
        deployer = session.deployer(clients)
        if kind == :destroy
          # The stack, not its name: the engine checks the stack's env against
          # the identity on a destroy, exactly as it does on a deploy.
          return deployer.destroy(stack:, identity:, options: session.destroy_options)
        end

        # The deploy step of architecture section 8: the stack's assets are in
        # their bucket before any change set is asked for. A stack with no asset
        # uploads nothing and checks nothing.
        published = Assets.publish(stack, store: clients.store, owner: identity.account)
        session.io.debug("#{entry.name}: assets #{published[:uploaded]} uploaded, #{published[:skipped]} already in the bucket")

        deployer.deploy(stack:, template: session.template_of(entry), identity:, options: session.deploy_options)
      end

      # For --json, one object on standard out per stack (architecture section
      # 11): name, stack id, outcome, exit code, changes, outputs, the error
      # when it failed, and what --hotswap did when it was in play. Nothing
      # else is written there. An error carries the exit code its class
      # decides; code: overrides that, nil included.
      def record(name, result: nil, error: nil, code: :unset)
        return unless session.options.json

        exit_code =
          if code == :unset
            result&.exit_code || (error ? Deploy.exit_code_for(error) : nil)
          else
            code
          end
        object = {
          "name" => name,
          "stack_id" => result&.stack_id,
          "outcome" => result&.outcome&.to_s,
          "exit_code" => exit_code,
          "changes" => (result&.changes || []).map(&:to_h),
          "outputs" => result&.outputs || {}
        }
        object["hotswap"] = hotswap_facts(result&.hotswap) if result&.hotswap
        object["error"] = error.is_a?(Exception) ? error.message : error.to_s if error
        session.io.result("#{JSON.generate(object)}\n")
      end

      # The hotswap facts of one deploy, as the machine contract carries them:
      # the CDK's mode word, whether the change set took the deploy after all,
      # and the classification's two lists.
      def hotswap_facts(facts)
        {
          "mode" => facts.mode,
          "fell_back" => facts.fell_back,
          "swapped" => facts.swapped.map { |function| { "logical_id" => function.logical_id, "resource_type" => function.resource_type,
            "name" => function.name } },
          "non_hotswappable" => facts.non_hotswappable.map { |change| { "logical_id" => change.logical_id,
            "resource_type" => change.resource_type, "reason" => change.reason } }
        }
      end

      # The two lines above every hotswap deploy, printed once per command
      # where the CDK prints them (cdk-toolkit.ts:566-569 at
      # f7c9dca95f440a076c2abd61b66b984624b8548e): before the first stack.
      def warn_hotswap
        Deploy::Hotswap::WARNINGS.each { |line| session.io.say(line) }
      end
    end
  end
end
