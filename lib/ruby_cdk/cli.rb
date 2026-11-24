# frozen_string_literal: true

require "thor"
require_relative "version"
require_relative "core"
require_relative "synth"
require_relative "assets"
require_relative "deploy"
require_relative "cli/io"
require_relative "cli/failure"
require_relative "cli/shell"
require_relative "cli/arguments"
require_relative "cli/pairs"
require_relative "cli/selection"
require_relative "cli/session"
require_relative "cli/aws"
require_relative "cli/synth"
require_relative "cli/list"
require_relative "cli/operation"
require_relative "cli/report"

module RubyCdk
  # The command line. One executable, `ruby-cdk` (architecture section 11).
  #
  # This class is the edge of the command line. It declares the options and the
  # commands, hands each command to one object under RubyCdk::Cli that answers
  # with an exit code, and turns what was raised into a message and a code
  # (section 14). Nothing under it exits, prints to the real streams on its own
  # or builds a client: `main` is the one place that exits, and it is all that
  # `exe/ruby-cdk` calls.
  #
  # The CDK CLI is the reference for every option here (aws/aws-cdk-cli at
  # eca1b73d682d7763955bec30ab5dd52bbc4327b6, packages/aws-cdk/lib/cli/parse-command-line-arguments.ts):
  # the names it gives them, their short forms, and what they say they do.
  class CLI < Thor
    package_name "ruby-cdk"
    check_unknown_options!

    # Thor comes with a `tree` command of its own, which lists Thor classes.
    # It is not one of this tool's.
    remove_command :tree
    map.delete("-t")
    map.delete("--tree")

    # What Ctrl-C ends a command with: 128 and the number of SIGINT.
    INTERRUPTED = 130

    # --- the options every command takes (architecture section 11)

    class_option :app, type: :string, default: "cdk.rb", aliases: "-a",
      desc: "The app file, which creates exactly one RubyCdk::App. A relative path is read from the working directory"

    class_option :out, type: :string, default: App::DEFAULT_OUT_DIR, aliases: "-o",
      desc: "Directory the templates and manifest.json are written to. An App the app file creates with out_dir: keeps its own"

    class_option :profile, type: :string, desc: "The AWS profile that selects the credentials"

    class_option :region, type: :string,
      desc: "The AWS region the clients are built for. A stack with an env deploys only into that region"

    class_option :account, type: :string,
      desc: "The 12-digit account the credentials must be for. Required with --yes for a stack without env"

    class_option :yes, type: :boolean, aliases: "-y", desc: "Deploy or destroy without asking for approval"

    class_option :force, type: :boolean, aliases: "-f",
      desc: "Deploy even when the template and the parameters are unchanged; with destroy, do not ask for confirmation"

    class_option :quiet, type: :boolean, aliases: "-q", desc: "Print no progress, and for synth no template"

    class_option :verbose, type: :boolean, aliases: "-v",
      desc: "Say what the command decides, and print the backtrace of an error"

    class_option :json, type: :boolean, aliases: "-j",
      desc: "Print the result as JSON on standard output; what is for a person goes to standard error"

    class_option :color, type: :boolean,
      desc: "Use colour even when standard output is not a terminal. --no-color never uses it"

    # --- the commands

    desc "version", "Print the gem version"
    def version
      session.io.line(RubyCdk::VERSION)
      Cli::SUCCESS
    end
    map "--version" => :version

    desc "synth [STACK...]", "Synthesize the app into --out, and print the template of the stack when there is one"
    def synth(*names)
      Cli::Synth.run(session, names)
    end

    desc "ls [STACK...]", "List the stacks of the app, one per line"
    method_option :long, type: :boolean, aliases: "-l", desc: "Show where each stack deploys"
    def ls(*names)
      Cli::List.run(session, names)
    end
    map "list" => :ls

    desc "deploy [STACK...]", "Deploy the stacks through CloudFormation change sets"
    method_option :all, type: :boolean, desc: "Deploy every stack of the app, dependencies first"
    method_option :exclusively, type: :boolean, aliases: "-e",
      desc: "Deploy only the stacks named, not the ones they depend on"
    method_option :execute, type: :boolean, default: true,
      desc: "Execute the change set. --no-execute leaves it to execute in the console"
    method_option :on_failure, type: :string, default: "DELETE",
      desc: "What CloudFormation does when a first deploy fails: DELETE, ROLLBACK or DO_NOTHING"
    method_option :parameters, type: :string,
      desc: "Template parameters for the deploy, as KEY=VALUE pairs separated by commas"
    method_option :tags, type: :string, desc: "Tags for the stacks, as KEY=VALUE pairs separated by commas"
    method_option :outputs_file, type: :string, aliases: "-O",
      desc: "File the outputs of each stack are written to, as JSON"
    def deploy(*names)
      Cli::Operation.new(session, kind: :deploy).call(names)
    end

    desc "destroy [STACK...]", "Delete the stacks from CloudFormation"
    method_option :all, type: :boolean, desc: "Destroy every stack of the app, the depended-on ones last"
    method_option :exclusively, type: :boolean, aliases: "-e",
      desc: "Destroy only the stacks named, not the ones that depend on them"
    def destroy(*names)
      Cli::Operation.new(session, kind: :destroy).call(names)
    end

    no_commands do
      # What a command starts with: its session, built from what the edge was
      # given. Colour is decided here as the CDK decides it (cli.ts:74-83 in
      # aws-cdk-cli): --no-color, then --color, then whether standard output is
      # a terminal.
      def session
        parsed = Cli::Session.options_from(options)
        io = shell.io
        io.color = parsed.color.nil? ? io.terminal? : parsed.color
        io.verbose = !!parsed.verbose
        Cli::Session.new(command: current_command_chain.first.to_s, options: parsed, io:, aws: shell.aws)
      end
    end

    class << self
      # Help and usage errors name the executable, however the file was called.
      def basename
        "ruby-cdk"
      end

      # Exits with the command's exit code. The one place the command line
      # exits, and what `exe/ruby-cdk` calls.
      def main(argv = ARGV)
        exit run(argv)
      rescue Interrupt
        exit INTERRUPTED
      end

      # Runs the command line in this process and answers its exit code
      # (architecture section 14). io is where it writes; aws is the object that
      # builds its clients, which a test replaces so that none is ever built.
      def run(argv = ARGV, io: Cli::Io.standard, aws: Cli::Aws)
        words = Cli::Arguments.command_first(Array(argv), commands: all_commands.keys + map.keys, switches: class_options)
        named = words.first
        shell = Cli::Shell.new(io, aws)

        unless named && (command?(named) || !named.start_with?("-"))
          # No command was named. The CDK asks for one too (demandCommand(1),
          # parse-command-line-arguments.ts:1281 in aws-cdk-cli): the help, and exit 1.
          help(shell)
          io.failure("Run `ruby-cdk help COMMAND` to read about a command, for example `ruby-cdk help deploy`.")
          return Cli::USAGE
        end

        # Thor shifts the command's word off the array it is given.
        code = dispatch(nil, words, nil, shell:)
        # A command answers its exit code. Thor's own help answers whatever it printed with.
        code.is_a?(Integer) ? code : Cli::SUCCESS
      rescue Errno::EPIPE
        # Standard out was closed under the command, as by `head`: nothing more to write.
        Cli::SUCCESS
      rescue StandardError, ScriptError => e
        Cli.report(e, io:, command: command?(named) ? named : nil)
      end

      # True for a word that names a command, a command's alias, --version or -h.
      def command?(word)
        !!(word && (all_commands.key?(word.tr("-", "_")) || map.key?(word)))
      end
    end
  end
end
