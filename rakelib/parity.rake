# frozen_string_literal: true

require "rbconfig"

desc "The scoreboard of the CDK's own tests, ported, in one process with no AWS credential reachable"
task :parity do
  sh RbConfig.ruby, "-Itest", "tools/parity.rb"
end
