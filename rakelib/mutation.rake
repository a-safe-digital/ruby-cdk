# frozen_string_literal: true

require "rbconfig"
require_relative "../tools/mutation_check"

desc "Every mutation in test/mutations leaves its test file red (docs/07-testing.md, section 10)"
task :mutation do
  survived = []
  failed = []

  Mutations::ALL.each do |name, mutation|
    print "#{name} (#{mutation[:file]}): "
    # A child process per mutation: the classes it changes are the process's own.
    # Exit 0 is the tests going red, 3 is their staying green.
    sh RbConfig.ruby, "-Itest", "tools/mutation_check.rb", name do |ok, status|
      case status.exitstatus
      when 0 then puts "caught"
      when 3 then puts "SURVIVED"; survived << name
      else failed << name
      end
    end
  end

  puts
  puts "Mutation: #{Mutations::ALL.length - survived.length - failed.length} of #{Mutations::ALL.length} caught."
  unless survived.empty?
    puts "Survived, which means these tests do not check what they claim:"
    survived.each { |name| puts "  #{name}" }
  end
  unless failed.empty?
    puts "Could not be run:"
    failed.each { |name| puts "  #{name}" }
  end

  raise "mutation: #{survived.length} survived, #{failed.length} not run" unless survived.empty? && failed.empty?
end
