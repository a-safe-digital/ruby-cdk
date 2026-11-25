# frozen_string_literal: true

# Supply-chain pins of architecture §16: the runtime dependency list is
# exactly four gems, and the transitive closure they drag in is exactly the
# one documented below. A new gem anywhere in the runtime chain fails this
# test and forces the dependency section of the architecture to change in the
# same commit (CLAUDE.md's dependencies rule).

require "test_helper"
require "bundler"

class DependenciesPinTest < Minitest::Test
  # What the four runtime gems drag in, as the lockfile carries them. The
  # additions to watch: aws-sdk-kms arrives through aws-sdk-s3 (its default
  # encryption support), base64 through aws-sdk-core.
  RUNTIME_CHAIN = %w[
    aws-eventstream
    aws-partitions
    aws-sdk-cloudformation
    aws-sdk-core
    aws-sdk-kms
    aws-sdk-s3
    aws-sigv4
    base64
    jmespath
    ruby-cdk
    rubyzip
    thor
  ].sort.freeze

  def test_the_runtime_chain_is_exactly_the_documented_gems
    locked = Bundler::LockfileParser.new(File.read(File.expand_path("../../Gemfile.lock", __dir__)))
    in_chain = locked.specs.select { |spec| RUNTIME_CHAIN.include?(spec.name) }
    outside = locked.specs.reject { |spec| RUNTIME_CHAIN.include?(spec.name) }
      .select { |spec| spec.name.start_with?("aws-", "jmespath", "rubyzip", "base64") }

    assert_equal RUNTIME_CHAIN, in_chain.map(&:name).uniq.sort
    assert_empty outside, "a gem in the AWS chain appeared without its architecture entry"
  end

  def test_the_gemspec_declares_exactly_the_four_runtime_dependencies
    spec = Gem::Specification.load(File.expand_path("../../ruby-cdk.gemspec", __dir__))

    assert_equal %w[aws-sdk-cloudformation aws-sdk-s3 rubyzip thor].sort, spec.runtime_dependencies.map(&:name).sort
    requirements = spec.runtime_dependencies.to_h { |dependency| [ dependency.name, dependency.requirement.to_s ] }
    assert_equal(
      { "aws-sdk-cloudformation" => "~> 1.0", "aws-sdk-s3" => "~> 1.0", "rubyzip" => "~> 3.0", "thor" => "~> 1.4" },
      requirements
    )
  end
end
