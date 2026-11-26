# frozen_string_literal: true

require "test_helper"
require "thor"
require "ruby_cdk/cli/failure"
require "ruby_cdk/cli/report"

# The report of an unexplained AWS failure: credential and SSO errors are
# explained as the preconditions they are (run aws sso login, refresh the
# credentials), never framed as bugs.
class CliReportTest < Minitest::Test
  def io
    @io ||= Struct.new(:out).new(+"").tap do |buffer|
      def buffer.failure(message) = self.out << "#{message}\n"
      def buffer.say(message) = self.out << "#{message}\n"
      def buffer.interactive? = false
      def buffer.verbose = false
    end
  end

  def text(io)
    io.out
  end

  # An AWS error shaped like the SSO failures the SDK raises: the failure
  # reporter matches on the class's name, so the stub is an anonymous class
  # whose name answers the Aws:: path without loading the SDK here.
  def aws_error(name, message)
    Class.new(StandardError).tap do |klass|
      klass.define_singleton_method(:name) { name }
      klass.define_method(:initialize) { @message = message }
      klass.define_method(:message) { @message }
    end.new
  end

  def test_an_sso_token_failure_is_explained_as_a_precondition
    error = aws_error("Aws::Errors::InvalidSSOToken", "Token is invalid and failed to refresh")

    code = RubyCdk::Cli.report(error, io:, command: "deploy")

    assert_equal 1, code
    assert_includes text(io), "Token is invalid and failed to refresh"
    assert_includes text(io), "aws sso login --profile PROFILE"
    refute_includes text(io), "Report it as a bug"
    refute_includes text(io), "not a failure the command line knows how to explain"
  end

  def test_an_expired_token_failure_is_explained_the_same_way
    error = aws_error("Aws::Errors::SSOError", "Error when retrieving token from sso: Token has expired and refresh failed")

    code = RubyCdk::Cli.report(error, io:, command: "deploy")

    assert_equal 1, code
    assert_includes text(io), "aws sso login --profile PROFILE"
    refute_includes text(io), "Report it as a bug"
  end

  def test_a_genuinely_unknown_aws_failure_still_reports_a_bug
    error = aws_error("Aws::Errors::SomethingElse", "the endpoint said no")

    code = RubyCdk::Cli.report(error, io:, command: "deploy")

    assert_equal 1, code
    assert_includes text(io), "Report it as a bug"
    refute_includes text(io), "aws sso login"
  end
end
