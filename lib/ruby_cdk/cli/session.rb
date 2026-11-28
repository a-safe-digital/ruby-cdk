# frozen_string_literal: true

require "json"
require_relative "../schema/validator"
require_relative "failure"
require_relative "pairs"

module RubyCdk
  module Cli
    # What one run of a command has: its options, its streams, the app file's
    # App once it is loaded, and the one object that builds AWS clients.
    #
    # Everything here hands over to a component: App.build! loads the app file,
    # App#synth writes the templates, the adapters resolve a region and build
    # the clients, the engine deploys. The session keeps what was asked for and
    # refuses, before anything runs, what cannot be used.
    class Session
      # Every option a command may take, as Thor parsed it. An option the
      # command does not take, or that was not given, is nil; a boolean that
      # was given is true.
      Options = Data.define(:app, :out, :profile, :region, :account, :yes, :force, :quiet, :verbose, :json, :color,
        :long, :all, :exclusively, :execute, :on_failure, :parameters, :tags, :outputs_file,
        :no_validate, :strict_types, :deployer, :fail, :security_only, :hotswap, :hotswap_fallback)

      # Thor's options as Options.
      def self.options_from(given)
        Options.new(**Options.members.to_h { |name| [ name, given[name] ] })
      end

      attr_reader :command, :options, :io, :aws

      def initialize(command:, options:, io:, aws:)
        @command = command
        @options = options
        @io = io
        @aws = aws
        @clients = {}
        @identities = {}
        check_paths
      end

      # The App the app file created, loaded once. Architecture section 11: the
      # file must create exactly one RubyCdk::App, and --out reaches an App the
      # file created without an out_dir of its own.
      def app
        @app ||= begin
          path = File.expand_path(options.app.to_s)
          unless File.file?(path)
            raise Usage.new("There is no app file at #{path}",
              next_step: "Run the command from the app's directory, or with --app PATH (the default is cdk.rb).")
          end

          io.debug("loading the app file #{path}")
          load_app(path)
        end
      end

      # Synthesis (architecture section 5), once: the templates are written and
      # the manifest answered. Raises RubyCdk::ValidationError when a rule fails.
      # The time it took is kept, for the line the CDK prints after it
      # (cdk-toolkit.ts in aws-cdk-cli: "Synthesis time: 4.43s").
      def manifest
        @manifest ||= begin
          started = clock
          synth_app.tap { @synthesis_seconds = clock - started }
        end
      end

      # --no-validate asks the pipeline to skip the schema rules: the tree's own
      # rules (V2, V13) still run, and the report command is how the rules are
      # seen without writing. The pipeline is asked with App#synth(validate:).
      # Until the pipeline takes the keyword (the core track is adding it), the
      # flag says so under --verbose and the validators still run: this method
      # flips to the keyword the moment the pipeline accepts it, and the call
      # above is the only place that changes.
      def synth_app
        return app.synth(validate: false) if options.no_validate && pipeline_takes_validate?

        io.debug("--no-validate: the pipeline does not take validate: yet, so the schema rules still ran") if options.no_validate
        app.synth
      end

      # The types architecture section 7 retains, as V15 is built with.
      def stateful_types
        Core::Stateful::RETAINED_TYPES + Core::Stateful::SNAPSHOT_TYPES
      end

      # --strict-types: the validators are registered once at umbrella load, so
      # strictness is a re-registration. Everything the umbrella registered is
      # taken out, and the same list built with strict_types: true goes in. The
      # pipeline's own V2 and V13 are left alone: the tree registers those
      # itself, and they were never taken out. Nothing is restored: a process
      # runs one command.
      def register_strict_validators
        return if @strict_registered

        RubyCdk::Synth.validators.each do |validator|
          next if validator.is_a?(RubyCdk::Synth::Rules::LogicalIds) || validator.is_a?(RubyCdk::Synth::Rules::StackName)

          RubyCdk::Synth.unregister_validator(validator)
        end
        RubyCdk::Validation.validators(strict_types: true, warnings: true, stateful_types: stateful_types)
          .each { |validator| RubyCdk::Synth.register_validator(validator) }
        @strict_registered = true
        io.debug("validators re-registered with strict_types: V1 makes an unknown type an error")
      end

      # The pipeline's warnings, once the pipeline carries them apart (the core
      # track is adding the list, and the manifest is what synthesize_app hands
      # over). Nothing under --quiet or --json, like the synthesis-time line.
      def say_warnings(manifest)
        return if options.quiet || options.json
        return unless manifest.respond_to?(:warnings)

        Array(manifest.warnings).each do |warning|
          io.say("warning #{warning.rule} #{warning.path}: #{warning.message}")
        end
      end

      # How long the one synthesis took, in seconds.
      def synthesis_seconds
        @synthesis_seconds
      end

      # The line after a synthesis, for a person. The CDK prints it after every
      # synthesis (cdk-toolkit.ts:522-523); it is silent for --quiet and --json,
      # which both keep the stream whole.
      def say_synthesis_time
        io.say(format("Synthesis time: %.2fs", synthesis_seconds)) unless options.quiet || options.json
      end

      def stacks
        app.stacks
      end

      def stack(name)
        stacks.find { |candidate| candidate.stack_name == name }
      end

      # The bytes of a stack's template, as they were written.
      def template_of(entry)
        File.binread(File.join(manifest.out_dir, entry.template))
      end

      # The region of a stack (architecture section 13): --region, else the
      # stack's env, else what the adapters resolve for the profile. The engine
      # refuses a stack whose env says otherwise.
      def region_of(stack)
        return options.region if options.region
        return stack.env.region if stack.env

        @region ||= aws.region(profile: options.profile, region: nil)
      end

      # Where region_of found it, for --verbose.
      def region_source(stack)
        if options.region
          " (--region)"
        elsif stack.env
          " (the stack's env)"
        else
          " (resolved for #{options.profile ? "profile #{options.profile}" : "the default credentials"})"
        end
      end

      # The clients of a region, built once per region.
      def clients(region:)
        @clients[region] ||= aws.clients(profile: options.profile, region: region)
      end

      # Who the credentials are, asked of the client once per region.
      def identity(clients)
        @identities[clients.object_id] ||= clients.cfn.resolve_identity
      end

      # The engine, with the output object the options select: Json for --json,
      # Quiet for --quiet, Human otherwise, which is also what --verbose gets.
      # The publisher is what a template too large for a request uses: it goes
      # into the stack's asset bucket and the change set carries its URL (§8).
      def deployer(clients)
        Deploy::Deployer.new(client: clients.cfn, store: clients.store, output: output,
          template_publisher: lambda { |stack, template|
            Assets.publish_template(stack, template, store: clients.store, owner: identity(clients).account)
          })
      end

      # What the engine is given for a deploy.
      def deploy_options
        check_hotswap_flags
        @deploy_options ||= Deploy::DeployOptions.new(
          parameters: Pairs.parse(options.parameters, option: "--parameters", command:),
          tags: Pairs.parse(options.tags, option: "--tags", command:),
          yes: !!options.yes,
          no_execute: options.execute == false,
          on_failure: on_failure,
          outputs_file: outputs_file,
          account: options.account,
          force: !!options.force,
          profile: options.profile,
          hotswap: !!options.hotswap,
          hotswap_fallback: !!options.hotswap_fallback
        )
      end

      # What the engine is given for a destroy. --yes skips the confirmation, as
      # architecture section 9 says, and so does --force, which is the CDK's own
      # flag for it (parse-command-line-arguments.ts:924-927 in aws-cdk-cli).
      def destroy_options
        @destroy_options ||= Deploy::DeployOptions.new(
          yes: !!options.yes || !!options.force,
          account: options.account,
          profile: options.profile
        )
      end

      # The engine's output object, on the session's streams.
      def output
        @output ||=
          if options.json
            Deploy::Output::Json.new(io: io.err, stdin: io.stdin, result_io: io.err)
          elsif options.quiet
            Deploy::Output::Quiet.new(io: io.err, stdin: io.stdin, result_io: io.out)
          else
            Deploy::Output::Human.new(io: io.err, stdin: io.stdin, result_io: io.out, color: io.color)
          end
      end

      private

    # The two flags are two forms of the same question, and the CDK refuses
    # the pair by name (cli.ts, determineHotswapMode at
    # f7c9dca95f440a076c2abd61b66b984624b8548e: ConflictingHotswapArgs).
    # Checked before any client is built, like every other option.
    def check_hotswap_flags
      return unless options.hotswap && options.hotswap_fallback

      raise Usage.new("Can not supply both --hotswap and --hotswap-fallback at the same time",
        next_step: "Run `ruby-cdk #{command}` again with only one of the two flags.")
    end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # True when the pipeline's synth takes the validate keyword.
      def pipeline_takes_validate?
        app.method(:synth).parameters.any? { |_kind, name| name == :validate }
      end

      # The app file, or the error placed where it happened.
      def load_app(path)
        App.build!(app_file: path, out_dir: options.out)
      rescue RubyCdk::Error => e
        # One of this gem's errors raised by the app file: it is already written
        # for a user, and it is still placed at the file's line.
        raise AppFileError.new(path, e) if AppFileError::Location.in(path, e)

        raise
      rescue ScriptError, StandardError => e
        raise AppFileError.new(path, e)
      end

      # --app, --out, --profile, --region and --account name something when they are given.
      def check_paths
        { app: "--app", out: "--out", profile: "--profile", region: "--region", account: "--account" }.each do |name, option|
          value = options.public_send(name)
          next unless value && value.to_s.strip.empty?

          raise Usage.new("#{option} must not be empty", next_step: "Run `ruby-cdk #{command}` again without #{option}, or with #{option} VALUE.")
        end
      end

      # --on-failure, checked against the engine's own table before any request,
      # so that a typo is a usage error and not a failed deploy.
      def on_failure
        wanted = options.on_failure.to_s
        unless Deploy::Deployer::ON_FAILURE.key?(wanted.downcase)
          raise Usage.new("--on-failure must be one of DELETE, ROLLBACK or DO_NOTHING, not #{wanted.inspect}",
            next_step: "Run `ruby-cdk #{command}` again with --on-failure DELETE.")
        end

        wanted
      end

      # --outputs-file, checked before any request: the engine writes it after a
      # deploy succeeded, and a path it cannot write to must not be found then.
      def outputs_file
        path = options.outputs_file
        return nil unless path

        if path.strip.empty?
          raise Usage.new("--outputs-file must not be empty", next_step: "Run `ruby-cdk #{command}` again with --outputs-file PATH.")
        end
        directory = File.dirname(File.expand_path(path))
        unless File.directory?(directory)
          raise Usage.new("The directory of --outputs-file does not exist: #{directory}",
            next_step: "Create it, or run `ruby-cdk #{command}` again with --outputs-file PATH in a directory that exists.")
        end

        path
      end
    end
  end
end
