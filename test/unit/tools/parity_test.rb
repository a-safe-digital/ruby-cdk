# frozen_string_literal: true

# The scoreboard that `rake parity` prints: one line per ported file, held to
# what its header says, and failing on anything the header does not explain.

require "test_helper"
require "tmpdir"
require_relative "../../../tools/parity"

class ParityTest < Minitest::Test
  FakeResult = Struct.new(:klass, :name, :failures, :source_location)

  class Sample
    def test_ok = nil
  end

  def test_the_summary_line_of_a_header
    header = [ "# Ported from the CDK.", "#", "# Parity: 23 cases in the origin; 14 ported; 9 not ported.", "", "require \"test_helper\"" ]

    assert_equal [ 23, 14, 9, nil ], Parity.summary_in(header)
    assert_equal [ 1, 1, 0, nil ], Parity.summary_in([ "# Parity: 1 case in the origin; 1 ported; 0 not ported." ])
    assert_equal [ 76, 76, 0, 2 ], Parity.summary_in([ "# Parity: 76 cases in the origin; 76 ported; 0 not ported; 2 tests." ])
  end

  def test_a_header_that_does_not_say
    assert_nil Parity.summary_in([ "# Ported, with no account of the original." ])
    assert_nil Parity.summary_in([ "# Ported.", "", "require \"test_helper\"", "# Parity: 1 case in the origin; 1 ported; 0 not ported." ]), "a comment after the header ended is code, not a header"
    assert_nil Parity.summary_in([ "# Parity: 23 cases in the origin; 14 ported." ]), "a line that leaves a count out"
  end

  def test_the_recorder_keeps_what_each_test_did_and_where
    recorder = Parity::Recorder.new
    where = Sample.instance_method(:test_ok).source_location
    recorder.record(FakeResult.new("ParityTest::Sample", "test_ok", [], where))
    recorder.record(FakeResult.new("ParityTest::Sample", "test_fails", [ Minitest::Assertion.new("wrong") ], where))
    recorder.record(FakeResult.new("ParityTest::Sample", "test_skips", [ Minitest::Skip.new ], where))
    recorder.record(FakeResult.new("ParityTest::Sample", "test_blows", [ RuntimeError.new("bug") ], where))

    assert_equal %i[passed failed skipped errored], recorder.outcomes.map(&:outcome)
    assert_equal [ where.first ], recorder.outcomes.map(&:file).uniq
    assert_equal "ParityTest::Sample#test_fails", recorder.outcomes[1].test
    refute recorder.passed?
  end

  def test_a_recorder_of_passing_tests_alone_passes
    where = Sample.instance_method(:test_ok).source_location
    recorder = Parity::Recorder.new
    recorder.record(FakeResult.new("ParityTest::Sample", "test_ok", [], where))

    assert recorder.passed?
  end

  def test_the_scoreboard_holds_each_file_to_its_header
    Dir.mktmpdir("ruby-cdk-parity") do |dir|
      good = write(dir, "good_test.rb", "# Parity: 3 cases in the origin; 3 ported; 0 not ported.")
      silent = write(dir, "silent_test.rb", "# No account of the original.")
      failing = write(dir, "failing_test.rb", "# Parity: 5 cases in the origin; 4 ported; 1 not ported.")
      wrong_sum = write(dir, "wrong_sum_test.rb", "# Parity: 5 cases in the origin; 4 ported; 2 not ported.")
      wrong_count = write(dir, "wrong_count_test.rb", "# Parity: 5 cases in the origin; 3 ported; 2 not ported.")
      as_data = write(dir, "as_data_test.rb", "# Parity: 20 cases in the origin; 20 ported; 0 not ported; 2 tests.")
      files = [ good, silent, failing, wrong_sum, wrong_count, as_data ]

      outcomes = passed(good, 3) + passed(silent, 1) + passed(failing, 3) + failed(failing, 1) + passed(wrong_sum, 4) + passed(wrong_count, 4) + passed(as_data, 2)
      lines, problems = Parity.scoreboard(outcomes, files:)

      assert_equal 6, lines.length

      assert_equal [
        "failing_test.rb: does not pass",
        "silent_test.rb: its header has no Parity line",
        "wrong_count_test.rb: says 3 ported, but holds 4 tests",
        "wrong_sum_test.rb: says 5 cases in the origin, but 4 ported and 2 not ported do not add up to that"
      ], problems.map { |problem| problem.delete_prefix("#{dir}/") }

      table = Parity.table(lines)
      files.each { |file| assert_includes table, File.basename(file) }
      # The totals count a file without its line as nothing.
      assert_match(/\ATotal\s+38\s+34\s+5\s+17\s+1\s+0\s+0\z/, table.lines.last, table)
    end
  end

  def test_cases_run_as_data_are_held_to_the_tests_that_carry_them
    Dir.mktmpdir("ruby-cdk-parity") do |dir|
      right = write(dir, "right_test.rb", "# Parity: 20 cases in the origin; 20 ported; 0 not ported; 2 tests.")
      wrong = write(dir, "wrong_test.rb", "# Parity: 20 cases in the origin; 20 ported; 0 not ported; 3 tests.")

      _lines, problems = Parity.scoreboard(passed(right, 2) + passed(wrong, 2), files: [ right, wrong ])

      assert_equal [ "wrong_test.rb: says 20 ported cases in 3 tests, but holds 2" ], problems.map { |problem| problem.delete_prefix("#{dir}/") }
    end
  end

  def test_a_scoreboard_where_everything_is_accounted_for
    Dir.mktmpdir("ruby-cdk-parity") do |dir|
      whole = write(dir, "whole_test.rb", "# Parity: 2 cases in the origin; 2 ported; 0 not ported.")
      part = write(dir, "part_test.rb", "# Parity: 4 cases in the origin; 1 ported; 3 not ported.")

      _lines, problems = Parity.scoreboard(passed(whole, 2) + passed(part, 1), files: [ whole, part ])

      assert_empty problems
    end
  end

  private

  def write(dir, name, last_line)
    path = File.join(dir, name)
    File.write(path, "# Ported.\n#{last_line}\n\nrequire \"test_helper\"\n")
    path
  end

  def passed(file, count)
    Array.new(count) { |index| Parity::Outcome.new(file:, test: "Klass#test_#{index}", outcome: :passed) }
  end

  def failed(file, count)
    Array.new(count) { |index| Parity::Outcome.new(file:, test: "Klass#test_#{index}", outcome: :failed) }
  end
end
