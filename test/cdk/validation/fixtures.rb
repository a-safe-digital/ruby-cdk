# frozen_string_literal: true

# What the ported validation suites share: one call of the whole component over a
# template, and the CDK's fixtures under test/fixtures/validation/cdk.
require "json"
require "test_helper"
require "ruby_cdk/schema/validator"

module ValidationFixtures
  # The report, with every rule and every warning in it.
  def validate_template(template)
    RubyCdk::Validation.validate(template,
      stack_name: "CdkValidation",
      stateful_types: RubyCdk::Core::Stateful::RETAINED_TYPES + RubyCdk::Core::Stateful::SNAPSHOT_TYPES)
  end

  # One of the CDK's fixtures under test/fixtures/validation/cdk/test-templates, by its
  # path from there, without the .json.
  def cdk_template(*path)
    full = File.expand_path(File.join("../../fixtures/validation/cdk/test-templates", *path), __dir__)
    JSON.parse(File.read("#{full}.json"))
  end
end
