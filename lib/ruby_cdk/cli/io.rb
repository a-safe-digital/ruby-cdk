# frozen_string_literal: true

module RubyCdk
  module Cli
    # The streams a command writes to, and the two settings that decide how.
    #
    # Standard out carries what is read by a machine: the template `synth`
    # prints, the JSON of `--json`, the outputs the engine prints. Everything
    # said to a person goes to standard error, so that `ruby-cdk synth >
    # stack.json` and `ruby-cdk deploy --json | jq` read clean output.
    class Io
      RED = "\e[31m"
      RESET = "\e[0m"

      # Decided by each command from its options: colour only when allowed and
      # wanted, --verbose on or off.
      attr_accessor :color, :verbose
      attr_reader :out, :err, :stdin

      def initialize(out: $stdout, err: $stderr, stdin: $stdin, color: false, verbose: false)
        @out = out
        @err = err
        @stdin = stdin
        @color = color
        @verbose = verbose
      end

      # The real streams. A command decides colour and verbosity from its options.
      def self.standard
        new
      end

      # Standard out, exactly as given. The caller ends it with a newline.
      def result(text)
        out.print(text)
      end

      # One line on standard out.
      def line(text = "")
        out.puts text
      end

      # One line to a person, on standard error.
      def say(text = "")
        err.puts text
      end

      # What the command decided, for --verbose.
      def debug(text)
        say("ruby-cdk: #{text}") if verbose
      end

      # A failure, in red when there is colour.
      def failure(text)
        err.puts(color ? "#{RED}#{text}#{RESET}" : text)
      end

      # True when there is somebody to answer a question: a terminal on both
      # standard input and standard output.
      def interactive?
        [ stdin, out ].all? { |stream| stream.respond_to?(:tty?) && stream.tty? }
      end

      # True when the command may use colour on standard out.
      def terminal?
        out.respond_to?(:tty?) && out.tty?
      end
    end
  end
end
