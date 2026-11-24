# frozen_string_literal: true

module RubyCdk
  module Cli
    # Thor's shell, writing to the streams the command line was given instead
    # of the real ones, so that help and usage errors are read by a test like
    # any other output. It is the plain shell: nothing the command line prints
    # through Thor carries colour, whatever --no-color says.
    #
    # It also carries what the edge was given, for the commands to build their
    # session from: the streams, and the one object that builds AWS clients.
    class Shell < Thor::Shell::Basic
      attr_reader :io, :aws

      def initialize(io, aws)
        super()
        @io = io
        @aws = aws
      end

      def stdout
        io.out
      end

      def stderr
        io.err
      end
    end
  end
end
