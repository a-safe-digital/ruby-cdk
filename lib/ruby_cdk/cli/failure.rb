# frozen_string_literal: true

module RubyCdk
  module Cli
    # The two exit codes the command line decides by itself. The others are
    # decided by the class of the error (RubyCdk::Deploy.exit_code_for), or
    # carried by a result of the engine (architecture section 14).
    SUCCESS = 0
    USAGE = 1

    # Exit 1: the command line was asked for something it cannot do, which is a
    # problem of the options or of the command, never of AWS or of the template.
    #
    # Architecture section 14: every failure ends with the command to run next
    # when there is an obvious one. next_step is that line, whole, as
    # "Run `ruby-cdk deploy --all`."; nil when nothing is obvious.
    class Usage < RubyCdk::UsageError
      attr_reader :next_step

      def initialize(message, next_step: nil)
        @next_step = next_step
        super(message)
      end
    end

    # Exit 1: the app file raised while it ran.
    #
    # Architecture section 11: such an error is reported at the user's file and
    # line, not inside the gem. error is what was raised, and location is the
    # first frame of its backtrace that is in the app file.
    class AppFileError < RubyCdk::Error
      attr_reader :path, :error, :location

      def initialize(path, error)
        @path = path
        @error = error
        @location = Location.in(path, error)
        super("#{error.class}: #{error.message}")
      end

      # True when what was raised is one of this gem's errors, from the tree the
      # app file was building: its message is already written for a user.
      def gem_error?
        error.is_a?(RubyCdk::Error)
      end

      # The backtrace of what was raised, gem frames included. For --verbose.
      def backtrace
        error.backtrace || []
      end

      # Where in the app file the error happened: a line, and what was running there.
      Location = Data.define(:line, :label) do
        # The first frame of the error's backtrace that is in the file, or nil
        # when the file raised nothing of its own. A syntax error is different:
        # it has no frame in the file, and its message starts with the line.
        def self.in(path, error)
          if error.is_a?(SyntaxError) && error.message.start_with?("#{path}:")
            line, rest = error.message.delete_prefix("#{path}:").split(":", 2)
            return new(line: Integer(line, exception: false), label: rest&.lines&.first&.strip)
          end

          frame = Array(error.backtrace).find { |entry| entry.start_with?("#{path}:") }
          return nil unless frame

          _path, line, rest = frame.split(":", 3)
          new(line: Integer(line, exception: false), label: rest&.strip)
        end

        # "line 4, in `<main>'".
        def to_s
          return "line #{line}" if label.nil? || label.empty?
          return label if line.nil?

          "line #{line}, #{label}"
        end
      end
    end
  end
end
