# frozen_string_literal: true

require "json"
require_relative "failure"
require_relative "pairs"

module RubyCdk
  module Cli
    # `synth`: every phase of architecture section 5 on every stack of the app,
    # which writes the templates and the manifest, and then the template on
    # standard out.
    #
    # What is printed is the CDK's synth (packages/aws-cdk/lib/cli/cdk-toolkit.ts:1123-1165
    # in aws-cdk-cli at eca1b73d682d7763955bec30ab5dd52bbc4327b6): one stack,
    # or one named, has its template on standard out unless --quiet; several
    # stacks put nothing there and say why on standard error. This tool writes
    # JSON only, so the CDK's `--json` (JSON instead of YAML) is something else
    # here: the content of the manifest, on standard out.
    module Synth
      # names are the STACK words: the template of the one stack named is the
      # one printed. Answers the exit code.
      def self.run(session, names)
        manifest = session.manifest
        session.say_synthesis_time
        entries = named(manifest.entries, names, session)
        io = session.io
        io.debug("synthesized #{manifest.entries.length} stack(s) into #{File.expand_path(manifest.out_dir)}")

        if session.options.json
          io.result(manifest.bytes)
        elsif !session.options.quiet && entries.one?
          io.result(session.template_of(entries.first))
        end
        return Cli::SUCCESS if session.options.json

        if names.empty? && manifest.entries.length > 1
          io.say("Successfully synthesized to #{File.expand_path(manifest.out_dir)}")
          io.say("Supply a stack id (#{manifest.entries.map(&:name).join(", ")}) to display its template.")
        end
        Cli::SUCCESS
      end

      # The entries the names stand for; every entry when none was given.
      def self.named(entries, names, session)
        names = names.compact
        return entries if names.empty?

        missing = names - entries.map(&:name)
        unless missing.empty?
          Kernel.raise Usage.new("No stacks match the name(s) #{missing.join(", ")}",
            next_step: "Run `ruby-cdk ls` to see the stacks of the app, then `ruby-cdk synth STACK`.")
        end
        entries.select { |entry| names.include?(entry.name) }
      end
    end
  end
end
