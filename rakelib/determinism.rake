# frozen_string_literal: true

require "rbconfig"
require "fileutils"
require "tmpdir"

# Determinism (architecture §18): every example synthesized twice, in child
# processes whose Ruby hash seeds differ from each other on purpose, and every
# byte of both trees compared with each other and with the committed fixtures
# under test/fixtures/templates/. Nothing here synthesizes in this process and
# nothing here reaches AWS: the children run `ruby-cdk synth`, which never
# loads the SDK.
#
# A difference is a finding about a component, never masked here: the task
# prints the file and the first lines that differ, and fails.
module Tools
  module Determinism
    # sh is Rake's, like the corpus fetch's.
    extend Rake::FileUtilsExt

    SEEDS = %w[1 42424].freeze

    # The examples with committed fixtures, as the snapshot harness keeps them.
    EXAMPLES = { "hello" => "examples/hello/cdk.rb" }.freeze
    ROOT = File.expand_path("..", __dir__)

    module_function

    def run
      failures = []
      EXAMPLES.each do |name, app_file|
        failures.concat(check(name, app_file))
      end

      if failures.empty?
        puts "determinism: #{EXAMPLES.keys.join(", ")}: byte-identical across two runs with different hash seeds, " \
          "and equal to the committed fixtures"
      else
        abort "determinism: #{failures.length} difference(s):\n\n#{failures.join("\n\n")}"
      end
    end

    def check(name, app_file)
      fixture = File.join(ROOT, "test", "fixtures", "templates", name)
      unless File.directory?(fixture)
        return [ "#{name}: no committed fixture at #{fixture}. Write it once with UPDATE_SNAPSHOTS=1 " \
          "(the snapshot test writes it) and commit it." ]
      end

      trees = SEEDS.map do |seed|
        dir = Dir.mktmpdir("ruby-cdk-determinism")
        synth(dir, seed, app_file)
        [ dir, files_of(dir) ]
      end

      problems = []
      first, second = trees
      (first.last - second.last).each { |file| problems << "#{name}: #{file} written by one run and not the other" }
      (second.last - first.last).each { |file| problems << "#{name}: #{file} written by one run and not the other" }
      (first.last & second.last).each do |file|
        one = File.binread(File.join(first.first, file))
        other = File.binread(File.join(second.first, file))
        next if one == other

        problems << "#{name}: #{file} differs between hash seed #{SEEDS[0]} and #{SEEDS[1]}:\n#{first_difference(one, other)}"
      end
      first.last.each do |file|
        one = File.binread(File.join(first.first, file))
        expected = File.join(fixture, file)
        unless File.file?(expected)
          problems << "#{name}: #{file} is not in the committed fixture"
          next
        end
        next if one == File.binread(expected)

        problems << "#{name}: #{file} differs from the committed fixture:\n" \
          "#{first_difference(one, File.binread(expected))}\n" \
          "If the change is meant, update the fixture with UPDATE_SNAPSHOTS=1 and review it in the pull request."
      end
      puts "determinism: #{name}: #{first.last.length} file(s), identical across hash seeds #{SEEDS.join(" and ")}"

      problems
    ensure
      trees&.each { |dir, _| FileUtils.remove_entry(dir) }
    end

    # One synthesis, in a child process pinned to one hash seed: two runs of
    # this task never share the seed, so anything the seed could move shows.
    def synth(dir, seed, app_file)
      ENV["RUBY_HASH_SEED"] = seed
      sh RbConfig.ruby, "-Ilib", File.join(ROOT, "exe", "ruby-cdk"), "--app", app_file, "--out", dir, "--quiet", "synth"
    ensure
      ENV.delete("RUBY_HASH_SEED")
    end

    def files_of(root)
      Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) }
        .map { |path| path.delete_prefix("#{root}/") }.sort
    end

    # The first lines that differ, for the report.
    def first_difference(one, other)
      one_lines = one.each_line.map(&:chomp)
      other_lines = other.each_line.map(&:chomp)
      index = (0...(one_lines.length)).find { |i| one_lines[i] != other_lines[i] } || one_lines.length
      "  run #{SEEDS[0]}: #{one_lines[index].inspect}\n  run #{SEEDS[1]}: #{other_lines[index].inspect}"
    end
  end
end

desc "Synthesize every example twice, with different Ruby hash seeds, and compare every byte " \
     "of both trees with each other and with the committed fixtures"
task :determinism do
  Tools::Determinism.run
end
