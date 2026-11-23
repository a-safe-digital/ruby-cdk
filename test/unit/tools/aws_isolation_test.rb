# frozen_string_literal: true

require "test_helper"
require_relative "../../../tools/aws_isolation"

class AwsIsolationTest < Minitest::Test
  def test_the_scrub_removes_every_aws_and_ruby_cdk_variable
    env = {
      "PATH" => "/usr/bin", "HOME" => "/home/someone",
      "AWS_PROFILE" => "production", "AWS_ACCESS_KEY_ID" => "AKIAEXAMPLE", "AWS_REGION" => "eu-west-1",
      "RUBY_CDK_AWS_PROFILE" => "sandbox", "RUBY_CDK_ALLOW_ACCOUNT" => "111122223333"
    }

    scrubbed = Tools::AwsIsolation.scrubbed_env(env)

    assert_equal "/usr/bin", scrubbed["PATH"]
    assert_equal "/home/someone", scrubbed["HOME"]
    assert_equal "/dev/null", scrubbed["AWS_CONFIG_FILE"]
    assert_equal "/dev/null", scrubbed["AWS_SHARED_CREDENTIALS_FILE"]
    assert_equal "true", scrubbed["AWS_EC2_METADATA_DISABLED"]
    assert_equal "1", scrubbed["AWS_SDK_CONFIG_OPT_OUT"]
    left = scrubbed.keys.reject { |key| Tools::AwsIsolation::OVERRIDES.key?(key) }
    assert_empty left.grep(/\A(AWS_|RUBY_CDK_)/)
  end

  def test_scrubbed_recognises_a_scrubbed_environment
    assert Tools::AwsIsolation.scrubbed?(Tools::AwsIsolation.scrubbed_env({}))

    refute Tools::AwsIsolation.scrubbed?({})
    refute Tools::AwsIsolation.scrubbed?(Tools::AwsIsolation.scrubbed_env({}).merge("AWS_PROFILE" => "x"))
  end

  def test_this_test_process_has_no_aws_credential_in_its_environment
    assert_predicate Tools::AwsIsolation, :scrubbed?
  end
end
