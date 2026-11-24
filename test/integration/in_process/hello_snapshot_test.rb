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

class HelloSnapshotTest < Minitest::Test
  def test_the_hello_example_synth_exact_bytes
    if RubyCdk::Cli::Snapshots.updating?
      files, fixture = RubyCdk::Cli::Snapshots.update("hello", "examples/hello/cdk.rb")
      warn "UPDATE_SNAPSHOTS=1: #{files.join(", ")} written to #{fixture}"
      problems = []
    else
      problems = RubyCdk::Cli::Snapshots.compare("hello", "examples/hello/cdk.rb")
    end

    assert_empty problems, problems.join("\n\n")
  end
end
