# frozen_string_literal: true

# Crosses every component of the synthesis path, the umbrella that wires them,
# the command line's app loading and the committed fixture, so it runs in
# process here and not under one component's unit tests.
#
# Architecture §15: every example's template is compared byte for byte with a
# committed fixture; a difference fails this test with a diff; updating a
# fixture is a deliberate UPDATE_SNAPSHOTS=1 run reviewed in the pull request.

require "test_helper"
require "support/cli_snapshots"
require "json"

class AppSnapshotTest < Minitest::Test
  FIXTURE_TEMPLATE = File.expand_path("../../fixtures/templates/app/app.template.json", __dir__)

  def test_the_app_example_synth_exact_bytes
    if RubyCdk::Cli::Snapshots.updating?
      files, fixture = RubyCdk::Cli::Snapshots.update("app", "examples/app/cdk.rb")
      warn "UPDATE_SNAPSHOTS=1: #{files.join(", ")} written to #{fixture}"
      problems = []
    else
      problems = RubyCdk::Cli::Snapshots.compare("app", "examples/app/cdk.rb")
    end

    assert_empty problems, problems.join("\n\n")
  end

  def test_the_committed_template_validates_clean
    report = RubyCdk::Validation.validate(JSON.parse(File.binread(FIXTURE_TEMPLATE)), stack_name: "app")

    assert_empty report.issues, report.to_s
  end
end
