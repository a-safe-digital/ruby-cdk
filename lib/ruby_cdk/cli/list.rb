# frozen_string_literal: true

require "json"
require_relative "failure"

module RubyCdk
  module Cli
    # `ls`: the stacks of the app, one name per line, which is the CDK's list
    # (packages/aws-cdk/lib/commands/list-stacks.ts:50-51 in aws-cdk-cli at
    # eca1b73d682d7763955bec30ab5dd52bbc4327b6). Its `--long` adds where each
    # stack deploys. The CDK's --json only changes the long forms; here it is
    # the same list as one JSON array, decided in this tool.
    #
    # Nothing is synthesized: the tree exists as soon as the app file ran.
    module List
      # names are the STACK words: only those stacks. Answers the exit code.
      def self.run(session, names)
        names = names.compact
        stacks = session.stacks
        missing = names - stacks.map(&:stack_name)
        unless missing.empty?
          Kernel.raise Usage.new("No stacks match the name(s) #{missing.join(", ")}",
            next_step: "Run `ruby-cdk ls` without a name to see every stack of the app.")
        end
        stacks = stacks.select { |stack| names.include?(stack.stack_name) } if names.any?

        io = session.io
        if session.options.json
          io.result("#{JSON.generate(stacks.map { |stack| described(stack) })}\n")
        else
          stacks.each { |stack| io.line(session.options.long ? "#{stack.stack_name}\t#{where(stack)}" : stack.stack_name) }
        end
        Cli::SUCCESS
      end

      def self.described(stack)
        env = stack.env
        { "name" => stack.stack_name, "env" => env && { "account" => env.account, "region" => env.region } }
      end

      def self.where(stack)
        stack.env ? stack.env.name : "no env: it deploys wherever the credentials point"
      end
    end
  end
end
