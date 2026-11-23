# frozen_string_literal: true

require_relative "../tools/quality"
require_relative "../tools/aws_isolation"

Tools::AwsIsolation.scrub!

require "simplecov"
SimpleCov.start do
  add_filter "/test/"
  add_filter "/tools/"
  add_filter "/rakelib/"
  minimum_coverage line: Tools::COVERAGE_LINE_FLOOR
end

$LOAD_PATH.unshift(File.expand_path("..", __dir__))

require "minitest/autorun"
require "ruby_cdk"
