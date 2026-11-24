# frozen_string_literal: true

# What the validation tests share: the fixtures under test/fixtures/validation/templates,
# and one call that runs the whole component over a template the way a command would.
#
# The stateful list is core's (architecture §7); the tests are allowed to read it, as the
# umbrella will when it registers the validators.
require "json"
require "test_helper"
require "ruby_cdk/schema/validator"

module ValidationCase
  STATEFUL_TYPES = (RubyCdk::Core::Stateful::RETAINED_TYPES + RubyCdk::Core::Stateful::SNAPSHOT_TYPES).freeze
  FIXTURES = File.expand_path("../../fixtures/validation/templates", __dir__)

  def fixture(name)
    JSON.parse(File.read(File.join(FIXTURES, "#{name}.json")))
  end

  # The report for a template, with everything left in.
  def report_for(template, **options)
    RubyCdk::Validation.validate(template, stateful_types: STATEFUL_TYPES, **options)
  end

  def rules_of(report)
    report.issues.map(&:rule).tally
  end
end
