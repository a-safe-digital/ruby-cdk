# frozen_string_literal: true

require "json"
require_relative "failure"
require_relative "selection"

module RubyCdk
  module Cli
    # `diff`: the change preview of the stacks a deploy would deploy
    # (architecture section 10).
    #
    # The stacks are chosen the way deploy chooses them (module Selection,
    # read in packages/aws-cdk/lib/cli/cli.ts:800-819 in aws-cdk-cli at
    # eca1b73d682d7763955bec30ab5dd52bbc4327b6): the app's only stack when
    # nothing is named, a usage error otherwise, --all for every stack, a
    # named stack bringing its dependencies unless --exclusively. Each stack
    # is diffed against the template CloudFormation answers `get_template`
    # with, through the port, and never through anything else: this command
    # makes no other request, so it changes nothing.
    #
    # The CDK computes its diff through a change set, which is what tells it
    # which properties replace a resource. Ours reads that from the schema
    # model instead (architecture section 10), so diff makes no write-shaped
    # request against the account at all.
    #
    # Output is text for a person on standard error -- where the CDK prints
    # it too (its io host routes everything but result and error to standard
    # error) -- and, with --json, one machine object per stack on standard
    # output and nothing else there. The exit code is 0 with and without
    # differences, the CDK's default; --fail makes a difference exit 1, as
    # the CDK's --fail does. Under --security-only the CDK counts the stacks
    # with security changes and nothing else, for the closing line and for
    # the failure, and so does this command.
    module Diff
      def self.run(session, names)
        manifest = session.manifest
        session.say_synthesis_time
        selected = Selection.choose(session.stacks, names:, all: session.options.all, command: "diff")
        entries = Selection.ordered(manifest.entries, selected: selected.map(&:stack_name), direction: :up,
          exclusively: session.options.exclusively)
        announce_dependencies(session, selected, entries)
        session.io.debug("diff: #{entries.map(&:name).join(", ")}")

        security_only = !!session.options.security_only
        diffs = entries.map { |entry| one(session, entry) }

        if session.options.json
          diffs.each do |diff|
            session.io.result("#{JSON.generate(diff.to_h)}\n")
          end
        else
          diffs.each do |diff|
            text = RubyCdk::Diff.render(diff, quiet: !!session.options.quiet, security_only: security_only)
            session.io.say(text.chomp) unless text.empty?
          end
          session.io.say(summary(counted(diffs, security_only)))
        end

        session.options.fail && counted(diffs, security_only).positive? ? 1 : Cli::SUCCESS
      end

      # The CDK's closing line (cdk-toolkit.ts, `Number of stacks with
      # differences`): how many stacks change, not how many resources.
      def self.summary(count)
        "✨ Number of stacks with differences: #{count}"
      end

      # One stack, from synthesis's output to its diff.
      def self.one(session, entry)
        stack = session.stack(entry.name)
        region = session.region_of(stack)
        clients = session.clients(region:)
        session.io.debug("#{entry.name}: region #{region}#{session.region_source(stack)}")
        RubyCdk::Diff.for_stack(clients.cfn, entry.name, template: session.template_of(entry))
      end

      # The CDK deploys a named stack's dependencies and says so (cli.ts:821-839,
      # expandUp); a diff reads them too, since deploying the stack would.
      def self.announce_dependencies(session, selected, entries)
        return if session.options.all || session.options.exclusively

        extra = entries.map(&:name) - selected.map(&:stack_name)
        return if extra.empty?

        session.io.say("Including dependency stacks: #{extra.join(", ")}")
      end

      def self.counted(diffs, security_only)
        if security_only
          diffs.count { |diff| diff.security.has_changes? }
        else
          diffs.count { |diff| !diff.empty? }
        end
      end
      private_class_method :counted
    end
  end
end
