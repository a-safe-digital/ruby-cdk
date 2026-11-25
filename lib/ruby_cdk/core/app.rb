# frozen_string_literal: true

require_relative "construct"
require_relative "stateful"

module RubyCdk
  # The root of the tree.
  class App < Construct
    # Where synthesis writes when neither the app file nor the command says.
    DEFAULT_OUT_DIR = "cdk.out"

    attr_reader :env, :out_dir, :stack_name_prefix, :stateful_default

    class << self
      # The App the command line runs: the one build! returned, or when there
      # is none the only App in the process. Errors if there is none, or several.
      def current
        return @current if @current

        case instances.length
        when 1
          instances.first
        when 0
          raise UsageError, "There is no RubyCdk::App: the app file creates one with RubyCdk::App.new"
        else
          raise UsageError, "There are #{instances.length} RubyCdk::Apps and none was built by App.build!: a command needs exactly one"
        end
      end

      # Loads the app file and returns the one App it created. May be called
      # again in the same process: each call builds a new App and makes it current.
      #
      # out_dir is where the command that called wants its files written, as
      # the value of `--out`. An App the file creates with an explicit
      # out_dir: keeps its own; one it creates without takes this; and without
      # this either, DEFAULT_OUT_DIR.
      def build!(app_file:, out_dir: nil)
        path = File.expand_path(app_file.to_s)
        unless File.file?(path)
          raise UsageError, "There is no app file at #{path}"
        end
        if out_dir && !(out_dir.is_a?(String) && !out_dir.empty?)
          raise UsageError, "App.build!: out_dir must be the path of a directory or nil, got #{out_dir.inspect}"
        end

        created = with_out_dir_of_command(out_dir) { newly_created { evaluate_app_file(path) } }
        case created.length
        when 1
          @current = created.first
        when 0
          raise UsageError, "#{path} created no RubyCdk::App: the app file must create exactly one, with RubyCdk::App.new"
        else
          raise UsageError, "#{path} created #{created.length} RubyCdk::Apps: the app file must create exactly one"
        end
      end

      # The user's app file: the one load in the gem that is not a literal require.
      def evaluate_app_file(path)
        load(path)
      end

      # The directory the command asked for while the app file runs, as the
      # out_dir: given to build!. nil the rest of the time, so that an App
      # created outside a command writes under DEFAULT_OUT_DIR. It is read,
      # never written: build! sets it for the duration of the app file only.
      def out_dir_of_command
        @out_dir_of_command
      end

      # Every App created in this process, in creation order.
      def instances
        (@instances ||= []).dup.freeze
      end

      # Forgets every App, and which one is current. For tests, and for a tool
      # that builds one app after another in one process.
      def reset!
        @instances = []
        @current = nil
        @out_dir_of_command = nil
        nil
      end

      # Records an App as it is created. App#initialize calls it; nothing else does.
      def register(app)
        (@instances ||= []) << app
      end

      private

      # What the block created, as Apps.
      def newly_created
        before = instances.length
        yield
        (@instances || []).drop(before)
      end

      # The block runs with the command's directory in place, and whatever
      # happens in it, including an app file that raises, the value there
      # before is put back: nothing carries over to the next build!.
      def with_out_dir_of_command(out_dir)
        before = @out_dir_of_command
        @out_dir_of_command = out_dir
        yield
      ensure
        @out_dir_of_command = before
      end
    end

    def initialize(env: nil, out_dir: nil, stack_name_prefix: nil, stateful_default: :retain_except_on_create, &block)
      if env && !env.is_a?(Env)
        raise UsageError, "App.new: env must be a RubyCdk::Env, got #{env.inspect}"
      end
      directory = out_dir || App.out_dir_of_command || DEFAULT_OUT_DIR
      unless directory.is_a?(String) && !directory.empty?
        raise UsageError, "App.new: out_dir must be the path of a directory or nil, got #{out_dir.inspect}"
      end
      unless stack_name_prefix.nil? || stack_name_prefix.is_a?(String)
        raise UsageError, "App.new: stack_name_prefix must be a String or nil, got #{stack_name_prefix.inspect}"
      end

      super(nil, "App")
      @env = env
      @out_dir = directory
      @stack_name_prefix = stack_name_prefix
      @stateful_default = Core::Stateful.validate_default!(stateful_default)
      App.register(self)
      block.call(self) if block
    end

    # The stacks of the app, in the order they were created.
    def stacks
      @children.select { |child| child.is_a?(Stack) }.freeze
    end

    # Runs every phase on every stack and writes the templates and the manifest.
    # validate: false skips the registered validators; the value model of §4
    # still applies, so a template is always plain data.
    #
    # Declared here because it is the tree's contract. The synth component
    # implements it by reopening this class: core does not depend on synth.
    def synth(validate: true)
      raise NotImplementedError, "added by the synth component"
    end
  end
end
