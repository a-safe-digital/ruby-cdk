# frozen_string_literal: true

require "yaml"
require_relative "support"

# The corpus check (docs/07-testing.md §6): every template of the committed sample was
# synthesized by the CDK and accepted by CloudFormation, so an error of any rule is a
# false positive, and a warning outside the two the rules were made to give is one too.
#
# The two warnings this corpus gives by design:
#   V1 - a type the model does not know: every Custom::* resource of the assertion
#        stacks, AWS::CDK::Metadata, the AWS::Serverless types of the alpha packages,
#        and the types of services retired since the template was synthesized. Rule V1
#        is a warning for exactly these, and keys are then written verbatim.
#   V15 - a stateful type with DeletionPolicy Delete: the integ stacks delete what they
#        hold, so that a run leaves nothing behind. The rule warns for exactly this.
#
# Anything else goes through test/fixtures/validation/known_false_positives.yml, which
# may only shrink.
class ValidationCorpusTest < Minitest::Test
  include ValidationCase

  ROOT = File.expand_path("../../fixtures/corpus/templates", __dir__)
  FALSE_POSITIVES = File.expand_path("../../fixtures/validation/known_false_positives.yml", __dir__)
  DESIGNED_WARNINGS = %w[V1 V15].freeze

  def test_the_sample_is_the_whole_sample
    assert_operator Dir[File.join(ROOT, "**", "*.json")].size, :>=, 395
  end

  def test_no_template_is_rejected_and_every_warning_is_explained
    check = RubyCdk::Validation::CorpusCheck.new(ROOT, stateful_types: STATEFUL_TYPES)
    exceptions = YAML.safe_load(File.read(FALSE_POSITIVES))["exceptions"]

    unexplained = check.errors.reject { |path, issue| explained?(exceptions, path, issue) }
    assert_empty unexplained, "the corpus was rejected by this tool, and CloudFormation accepted it: #{check}"

    loose = check.warnings_by_rule.keys - DESIGNED_WARNINGS
    assert_empty loose, "a warning the rules were not made to give: #{check}"
    assert_equal 0, check.unparseable.size
  end

  def test_the_file_of_exceptions_only_shrinks
    entries = YAML.safe_load(File.read(FALSE_POSITIVES))["exceptions"]

    entries.each do |entry|
      assert entry["template"], "an exception names its template"
      assert entry["rule"], "an exception names its rule"
      assert entry["reason"], "an exception says why"
    end
  end

  private

  # An exception names a file (the name under templates/), a rule and, when it names
  # one, the path the issue sits at.
  def explained?(exceptions, path, issue)
    short = path.delete_prefix("#{ROOT}/")
    exceptions.any? do |entry|
      entry["template"] == short && entry["rule"] == issue.rule &&
        (!entry["path"] || entry["path"] == issue.path)
    end
  end
end
