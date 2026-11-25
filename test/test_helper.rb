# frozen_string_literal: true

require_relative "../tools/quality"
require_relative "../tools/aws_isolation"

Tools::AwsIsolation.scrub!

require "simplecov"

# The coverage floor applies to the whole suite, so only the full run enforces
# it. A single test file run on its own is judged by its tests.
FULL_SUITE = $PROGRAM_NAME.end_with?("test/runner.rb")

SimpleCov.start do
  # Only the directories at the root of the repository are left out. A string
  # such as "/test/" would also leave out lib/ruby_cdk/test/, the test kit, so
  # that its lines counted neither as covered nor as missed.
  add_filter %r{\A#{Regexp.escape(File.expand_path("..", __dir__))}/(?:test|tools|rakelib)/}
  minimum_coverage line: Tools::COVERAGE_LINE_FLOOR if FULL_SUITE
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "ruby_cdk"

# The synthesis pipeline is global state: its validators, normalizers and
# manifest facts are registered at umbrella load and suites legitimately mutate
# them — the command line's --strict-types test re-registers the validators
# strict, the schema's tests take single rules out and put them back, the
# pipeline's own tests add one-off normalizers. Under Minitest's global shuffle
# whatever a suite leaves behind decides what every later suite sees.
#
# The registry guard makes the suite order-independent by construction: before
# every test it snapshots the registries, after every test it restores exactly
# what was there. It is the safety net under a suite's own setup and teardown,
# not a replacement for them.
#
# Restoration reaches into the pipeline module's private registries rather than
# going through register/unregister: the public calls can put the members back
# but not their order, and the order of normalizers and validators is part of
# what a test under shuffle must see unchanged.
module RegistryGuard
  def before_setup
    @registry_snapshot = {
      validators: RubyCdk::Synth.validators.dup,
      normalizers: RubyCdk::Synth.normalizers.dup,
      manifest_facts: RubyCdk::Synth.send(:manifest_facts).dup,
      entry_facts: RubyCdk::Synth.send(:entry_facts).dup
    }
    super
  end

  def after_teardown
    super
    snapshot = @registry_snapshot
    return unless snapshot

    RubyCdk::Synth.send(:validators_registry).replace(snapshot[:validators].dup)
    RubyCdk::Synth.send(:normalizers_registry).replace(snapshot[:normalizers].dup)
    RubyCdk::Synth.send(:manifest_facts).replace(snapshot[:manifest_facts].dup)
    RubyCdk::Synth.send(:entry_facts).replace(snapshot[:entry_facts].dup)
    @registry_snapshot = nil
  end
end

Minitest::Test.send(:include, RegistryGuard)
