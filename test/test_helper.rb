# frozen_string_literal: true

require_relative "../tools/quality"
require_relative "../tools/aws_isolation"

Tools::AwsIsolation.scrub!

require "simplecov"

# The coverage floor applies to the whole suite, so only the full run enforces
# it. A single test file run on its own is judged by its tests.
FULL_SUITE = $PROGRAM_NAME.end_with?("test/runner.rb")

SimpleCov.start do
  # Only the directories at the root of the repository are left out. A string
  # such as "/test/" would also leave out lib/ruby_cdk/test/, the test kit, so
  # that its lines counted neither as covered nor as missed.
  add_filter %r{\A#{Regexp.escape(File.expand_path("..", __dir__))}/(?:test|tools|rakelib)/}
  minimum_coverage line: Tools::COVERAGE_LINE_FLOOR if FULL_SUITE
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "ruby_cdk"
