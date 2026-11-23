# frozen_string_literal: true

require "rbconfig"
require_relative "../tools/aws_isolation"

desc "Run the unit and snapshot tests with no AWS credential reachable"
task :test do
  Tools::AwsIsolation.scrub!
  sh RbConfig.ruby, "-Itest", "test/runner.rb"
end
