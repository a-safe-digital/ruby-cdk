# frozen_string_literal: true

require "test_helper"
require_relative "../../support/schema_fixtures"

# The alarm of decision D-005: what makes a downloaded source unusable.
class SourcesFetchTest < Minitest::Test
  Fetcher = RubyCdk::Schema::Sources::Fetcher
  URL = "https://example.invalid/source"
  DAY = 24 * 60 * 60

  def download(status: 200, last_modified: SchemaFixtures::LAST_MODIFIED)
    SchemaFixtures.download(URL, "body", status:, last_modified:)
  end

  def test_a_fresh_source_that_answers_200_has_no_problems
    assert_equal [], Fetcher.new.problems(download, now: SchemaFixtures::NOW)
  end

  def test_ninety_days_without_a_change_is_the_limit
    now = SchemaFixtures::NOW

    assert_equal 90 * DAY, Fetcher::MAX_AGE
    assert_equal [], Fetcher.new.problems(download(last_modified: now - 90 * DAY), now:)
    assert_equal 1, Fetcher.new.problems(download(last_modified: now - 90 * DAY - 1), now:).size
  end

  def test_a_stale_source_is_told_how_old_it_is
    problem = Fetcher.new.problems(download(last_modified: Time.utc(2026, 7, 1, 9, 30)), now: SchemaFixtures::NOW).first

    assert_equal "#{URL}: Last-Modified 2026-07-01, 145 days ago, more than the 90 of decision D-005", problem
  end

  def test_a_source_without_last_modified_cannot_be_judged
    problem = Fetcher.new.problems(download(last_modified: nil), now: SchemaFixtures::NOW).first

    assert_match(/no Last-Modified header, so its age cannot be checked/, problem)
  end

  def test_a_404_means_the_source_is_gone
    problem = Fetcher.new.problems(download(status: 404), now: SchemaFixtures::NOW).first

    assert_equal "#{URL}: HTTP 404. AWS has stopped publishing it there: see decision D-005", problem
  end

  def test_any_other_status_is_a_problem_too
    problems = [ 301, 403, 500 ].map { |status| Fetcher.new.problems(download(status:), now: SchemaFixtures::NOW).first }

    assert_equal [ "#{URL}: HTTP 301", "#{URL}: HTTP 403", "#{URL}: HTTP 500" ], problems
  end

  def test_a_last_modified_in_the_future_is_taken_as_fresh
    assert_equal [], Fetcher.new.problems(download(last_modified: SchemaFixtures::NOW + 3600), now: SchemaFixtures::NOW)
  end
end
