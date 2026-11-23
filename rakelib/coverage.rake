# frozen_string_literal: true

require "json"
require_relative "../tools/quality"

desc "Fail when the last test run covered fewer lines than the floor"
task "coverage:check" do
  path = File.expand_path("../coverage/.last_run.json", __dir__)
  unless File.file?(path)
    abort "coverage: no test run found under coverage/. Run `rake test` first."
  end

  covered = JSON.parse(File.read(path)).fetch("result").fetch("line")
  if covered < Tools::COVERAGE_LINE_FLOOR
    abort format("coverage: %.2f%% of lines covered, the floor is %d%%", covered, Tools::COVERAGE_LINE_FLOOR)
  end

  puts format("coverage: %.2f%% of lines covered (floor %d%%)", covered, Tools::COVERAGE_LINE_FLOOR)
end
