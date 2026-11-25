# frozen_string_literal: true

# The mutation check (docs/07-testing.md, section 10). A mutation changes a
# shipped class in memory, never a file, and the test file named beside it
# must then go red: a mutation that leaves its file green means the tests do
# not check what they claim.
#
# The mutations live in test/mutations/*.rb, one file per component. `rake
# mutation` runs each one in a child process through this script, because the
# classes it changes are the process's own.
#
#   ruby -Itest tools/mutation_check.rb <mutation>
#
# Exit status: 0 when the tests went red (the mutation was caught), 3 when
# they stayed green (it survived), anything else when it could not be run.
require_relative "aws_isolation"

require "minitest"

module Mutations
  # name => { file: the test file that must go red, apply: what changes }
  ALL = {}

  class << self
    def define(name, file, &apply)
      ALL[name] = { file:, apply: }
      nil
    end

    def swap_constant(owner, name, value)
      owner.send(:remove_const, name)
      owner.const_set(name, value)
    end

    # Replaces, or adds, a method of the class itself.
    def singleton(owner, &definition)
      owner.singleton_class.class_eval(&definition)
    end
  end
end

Dir[File.expand_path("../test/mutations/*.rb", __dir__)].sort.each { |path| require path }

if $PROGRAM_NAME == __FILE__
  # Only the script scrubs, never the require: rakelib/mutation.rake loads this
  # file while rake starts, and a scrub here would strip AWS_* and RUBY_CDK_*
  # from every rake invocation, `rake integration` and `rake sweep` included.
  Tools::AwsIsolation.scrub!
  name = ARGV.first
  if ARGV.length != 1 || !Mutations::ALL.key?(name)
    puts "usage: ruby -Itest tools/mutation_check.rb <mutation>"
    puts "mutations: #{Mutations::ALL.keys.join(", ")}"
    exit 2
  end
  mutation = Mutations::ALL.fetch(name)

  # The test files load minitest/autorun through test_helper, and the run is
  # this script's: autorun installs its handler only once, so it is told that
  # it already has.
  Minitest.class_variable_set(:@@installed_at_exit, true)

  root = File.expand_path("..", __dir__)
  $LOAD_PATH.unshift(File.join(root, "test"))
  require File.join(root, "test", "test_helper")

  mutation[:apply].call
  puts "mutation #{name}: applied"
  require File.join(root, mutation[:file])

  if Minitest.run([])
    puts "mutation #{name}: SURVIVED, its tests stayed green"
    exit 3
  end
  puts "mutation #{name}: caught"
end
