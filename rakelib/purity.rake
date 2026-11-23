# frozen_string_literal: true

require "rbconfig"

desc "Fail on JavaScript-toolchain usage or on a process call in the shipped code"
task :purity do
  sh RbConfig.ruby, File.expand_path("../tools/purity_check.rb", __dir__), File.expand_path("..", __dir__)
end
