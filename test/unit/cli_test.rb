# frozen_string_literal: true

require "test_helper"

require "ruby_cdk/cli"
require "stringio"

class CliTest < Minitest::Test
  def test_version_prints_the_gem_version
    out, _err = capture_io { RubyCdk::CLI.start([ "version" ]) }

    assert_equal "#{RubyCdk::VERSION}\n", out
  end

  def test_version_flag_prints_the_gem_version
    out, _err = capture_io { RubyCdk::CLI.start([ "--version" ]) }

    assert_equal "#{RubyCdk::VERSION}\n", out
  end
end
