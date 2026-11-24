# frozen_string_literal: true

# The boot script of `rake integration`. Only `rakelib/integration.rake` runs
# it, and only with the three variables of WF-5 in the environment. The suite's
# runner never loads this directory, and `rake test` never reaches AWS.
#
# Every check fails closed: the guard refuses before any request, and a stack
# or a resource left behind fails the run after the teardown.

require "ruby_cdk"

Dir[File.join(__dir__, "*.rb")].sort.each { |path| require path }
require "minitest/autorun"

# The scenarios, as Minitest, so that one failing scenario does not stop the
# teardown of another and the report is the usual one.
Dir[File.join(__dir__, "**", "*_test.rb")].sort.each { |path| require path }
