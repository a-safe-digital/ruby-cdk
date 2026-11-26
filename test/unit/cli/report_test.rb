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

  # A message that merely mentions "Token" or "SSO" — a CloudFormation or IAM
  # validation message, say — is not a credential precondition: the error keeps
  # its own reporting.
  def test_an_aws_failure_whose_message_mentions_a_token_is_not_a_credential_precondition
    error = aws_error("Aws::CloudFormation::Errors::ValidationError", "Template error: the SSO token property is invalid")

    code = RubyCdk::Cli.report(error, io:, command: "deploy")

    assert_equal 1, code
    refute_includes text(io), "aws sso login"
    assert_includes text(io), "Report it as a bug"
  end

  def test_the_credential_matcher_answers_true_only_for_the_named_classes
    assert RubyCdk::Cli.credential_failure?(
      aws_error("Aws::Errors::InvalidSSOToken", "Token is invalid and failed to refresh")
    ), "the SSO token class is the precondition"
    assert RubyCdk::Cli.credential_failure?(
      aws_error("Aws::STS::Errors::ExpiredToken", "Security token on the page is no longer valid")
    ), "the service's ExpiredToken class is the precondition"
    assert RubyCdk::Cli.credential_failure?(
      aws_error("Aws::Sigv4::Errors::MissingCredentialsError", "no credentials to sign with")
    ), "the signature failure has its own class"
    assert RubyCdk::Cli.credential_failure?(
      aws_error("Aws::Errors::MetadataParserError", "Failed to open TCP connection to 169.254.169.254")
    ), "the unreachable metadata endpoint has no class of its own"

    refute RubyCdk::Cli.credential_failure?(
      aws_error("Aws::CloudFormation::Errors::ValidationError", "Template error: SSO is not allowed here")
    ), "a message that mentions SSO is not the precondition"
    refute RubyCdk::Cli.credential_failure?(
      aws_error("StandardError", "Failed to open TCP connection to 169.254.169.254")
    ), "the message shape alone, outside Aws::, is not the precondition"
  end
end
