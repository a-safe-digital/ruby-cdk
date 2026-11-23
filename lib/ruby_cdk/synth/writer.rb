# frozen_string_literal: true

require "fileutils"
require_relative "../errors"

module RubyCdk
  module Synth
    # The write phase: a file is written only when its bytes changed.
    module Writer
      module_function

      # Writes bytes to path unless the file already holds them. Returns true
      # when the file was written.
      def write_if_changed(path, bytes)
        return false if File.file?(path) && File.binread(path).b == bytes.b

        File.binwrite(path, bytes)
        true
      rescue SystemCallError => e
        Kernel.raise UsageError, "Cannot write #{path}: #{e.message}"
      end

      # Makes path, and every directory above it that is missing.
      def mkdir(path)
        FileUtils.mkdir_p(path)
      rescue SystemCallError => e
        Kernel.raise UsageError, "Cannot create the directory #{path}: #{e.message}"
      end
    end
  end
end
