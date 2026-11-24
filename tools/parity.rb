# frozen_string_literal: true

# The scoreboard of the CDK's own tests, ported (docs/07-testing.md, section
# 11). `rake parity` runs this file.
#
# It runs every ported file under test/cdk in one process, with a recorder
# beside Minitest's own reporters, and prints one line per file: how many
# cases the original has, how many are ported, how many tests pass.
#
# A ported file ends its header with one line that accounts for the original:
#
#   # Parity: 23 cases in the origin; 14 ported; 9 not ported.
#
# The reasons for what is not ported stay in the prose above that line. A
# ported case is one test method, unless the file runs its cases as data; then
# the line says how many tests carry them:
#
#   # Parity: 76 cases in the origin; 76 ported; 0 not ported; 2 tests.
#
# The scoreboard fails on a test that does not pass, on a ported file without
# its line, on a line that does not add up, and on a line that disagrees with
# the number of tests in the file.
require_relative "aws_isolation"

Tools::AwsIsolation.scrub!

require "minitest"

module Parity
  ROOT = File.expand_path("..", __dir__)
  PORTED = File.join(ROOT, "test", "cdk")
  SUMMARY = /\A# Parity: (\d+) cases? in the origin; (\d+) ported; (\d+) not ported(?:; (\d+) tests?)?\.\z/

  # What one test did: the file that defines it, its name, and its outcome.
  Outcome = Data.define(:file, :test, :outcome)

  # What one ported file says about itself, and what its tests did. tests is
  # the number of test methods the header says carry the ported cases; nil
  # when it says nothing, which means one test per case.
  Line = Data.define(:file, :origin, :ported, :not_ported, :tests, :passed, :failed, :errored, :skipped)

  class << self
    # Every ported test file, sorted.
    def files
      Dir[File.join(PORTED, "**", "*_test.rb")].sort
    end

    # [cases in the origin, ported, not ported, tests or nil] from a file's
    # header, or nil when the header does not say.
    def summary_of(path)
      summary_in(File.readlines(path, chomp: true))
    end

    # The same, over the lines of a header: it ends at the first line that is
    # neither blank nor a comment.
    def summary_in(lines)
      lines.each do |line|
        text = line.strip
        next if text.empty?
        return nil unless text.start_with?("#")

        match = SUMMARY.match(text)
        return match.captures.map { |capture| capture&.to_i } if match
      end
      nil
    end

    # The scoreboard of a run: [one Line per ported file, the problems found].
    # files are the ported files; a test passes its own.
    def scoreboard(outcomes, files: files())
      lines = files.sort.map { |file| line_for(file, outcomes.select { |outcome| outcome.file == file }) }
      [ lines, lines.flat_map { |line| problems_of(line) } ]
    end

    # The table as it is printed.
    def table(lines)
      heading = format("%-52s %7s %7s %11s %5s %5s %5s %5s", "Ported file", "Origin", "Ported", "Not ported", "Pass", "Fail", "Error", "Skip")
      rows = lines.map do |line|
        counts = line.origin ? format("%7d %7d %11d", line.origin, line.ported, line.not_ported) : format("%7s %7s %11s", "-", "-", "-")
        format("%-52s %s %5d %5d %5d %5d", line.file.delete_prefix("#{ROOT}/"), counts, line.passed, line.failed, line.errored, line.skipped)
      end
      # A file without its Parity line counts as nothing in the totals; the
      # problems say so.
      totals = format("%-52s %7d %7d %11d %5d %5d %5d %5d", "Total", lines.sum { |line| line.origin || 0 },
        lines.sum { |line| line.ported || 0 }, lines.sum { |line| line.not_ported || 0 },
        lines.sum(&:passed), lines.sum(&:failed), lines.sum(&:errored), lines.sum(&:skipped))
      ([ heading ] + rows + [ totals ]).join("\n")
    end

    private

    def line_for(file, outcomes)
      summary = summary_of(file)
      Line.new(
        file:, origin: summary&.first, ported: summary&.at(1), not_ported: summary&.at(2), tests: summary&.at(3),
        passed: outcomes.count { |outcome| outcome.outcome == :passed },
        failed: outcomes.count { |outcome| outcome.outcome == :failed },
        errored: outcomes.count { |outcome| outcome.outcome == :errored },
        skipped: outcomes.count { |outcome| outcome.outcome == :skipped }
      )
    end

    def problems_of(line)
      where = line.file.delete_prefix("#{ROOT}/")
      return [ "#{where}: does not pass" ] unless line.failed.zero? && line.errored.zero? && line.skipped.zero?
      return [ "#{where}: its header has no Parity line" ] unless line.origin

      problems = []
      problems << "#{where}: says #{line.origin} cases in the origin, but #{line.ported} ported and #{line.not_ported} not ported do not add up to that" if line.origin != line.ported + line.not_ported
      ran = line.passed + line.failed + line.errored + line.skipped
      problems << if line.tests
        "#{where}: says #{line.ported} ported cases in #{line.tests} tests, but holds #{ran}"
      else
        "#{where}: says #{line.ported} ported, but holds #{ran} tests"
      end if (line.tests || line.ported) != ran
      problems
    end
  end

  # Beside Minitest's own reporters: keeps what every test did, with the file
  # that defines it.
  class Recorder < Minitest::AbstractReporter
    attr_reader :outcomes

    def initialize
      @outcomes = []
    end

    def record(result)
      @outcomes << Outcome.new(file: file_of(result), test: "#{result.klass}##{result.name}", outcome: outcome_of(result))
    end

    def passed?
      @outcomes.all? { |outcome| outcome.outcome == :passed }
    end

    private

    def outcome_of(result)
      failures = result.failures
      return :skipped if failures.any? { |failure| failure.is_a?(Minitest::Skip) }
      return :failed if failures.any? { |failure| failure.is_a?(Minitest::Assertion) }
      return :errored unless failures.empty?

      :passed
    end

    # Minitest records where each test is defined (Minitest::Result#source_location).
    def file_of(result)
      location = result.source_location
      return location.first if location && location.first != "unknown"

      Object.const_get(result.klass).instance_method(result.name.to_sym).source_location&.first
    rescue NameError
      nil
    end
  end

  # Minitest gives its reporters to its plugins and to nobody else: `run` builds
  # them, shows them to the plugins, and puts them away (minitest.rb, `run`).
  # So the recorder is added the way a plugin adds one.
  module Plugin
    def self.minitest_plugin_init(_options)
      Minitest.reporter << Parity.recorder
    end
  end

  class << self
    attr_accessor :recorder
  end
end

if $PROGRAM_NAME == __FILE__
  # The ported files load minitest/autorun through test_helper, and the run is
  # this script's: autorun installs its handler only once, so it is told that
  # it already has.
  Minitest.class_variable_set(:@@installed_at_exit, true)

  $LOAD_PATH.unshift(File.expand_path("../test", __dir__))

  ported = Parity.files
  abort "parity: there is no ported file under test/cdk" if ported.empty?

  ported.each { |path| require path }

  Parity.recorder = Parity::Recorder.new
  Minitest.extensions << Parity::Plugin
  passed = Minitest.run([])

  lines, problems = Parity.scoreboard(Parity.recorder.outcomes)
  puts
  puts Parity.table(lines)
  puts
  if problems.empty?
    puts "Parity: every case is ported or listed with its reason, and every ported one passes."
  else
    puts "Parity: #{problems.length} difference#{"s" if problems.length > 1} without a reason:"
    problems.each { |problem| puts "  #{problem}" }
    Parity.recorder.outcomes.reject { |outcome| outcome.outcome == :passed }.each { |outcome| puts "  #{outcome.test}: #{outcome.outcome}" }
  end

  exit(passed && problems.empty?)
end
