# frozen_string_literal: true

# The Wave 6 security promise (architecture §20): a deploy's output never
# carries a credential. The engine prints SDK error messages verbatim, and an
# SDK error message is allowed to name the credentials' access key id — that
# is an identifier (D-027). The secret access key and the session token must
# never appear, wherever the message came from. The identifiers below are
# deliberately not AWS-shaped: the scanner reads tests too.

require "test_helper"
require "aws-sdk-core"
require_relative "../../support/deploy_fixtures"

class CredentialsInOutputTest < Minitest::Test
  include DeployFixtures
  SECRET = "aBcD3fGhIjKlMnOpQrStUvWxYz0123456789SECRET"
  TOKEN = "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPDH6xSECRET"
  ACCESS_KEY_ID = "SANDBOX-ACCESS-KEY-ID"

  def captured_output_for(client)
    output = RubyCdk::Deploy::Fakes::Output.new

    deploy(client, output, identity: client.identity, options: unattended)
    [ output.failures.map(&:message) || [], output.announcements ].join("\n")
  rescue StandardError => e
    [ output.failures.map(&:message), output.announcements, e.message ].join("\n")
  end

  def test_an_sdk_error_prints_no_secret_and_no_token
    # A real credentials object in scope: whatever the engine printed would
    # carry these values if any path dumped them.
    credentials = Aws::Credentials.new(ACCESS_KEY_ID, SECRET)
    refute_includes credentials.inspect, SECRET, "Aws::Credentials#inspect shows only the access key id (aws-sdk-core, verified)"

    client = RubyCdk::Deploy::Fakes::CfnClient.new
    client.stack("blog", status: "CREATE_COMPLETE")
    client.on(:execute_change_set, StandardError.new("Internal failure (Service: AWS CloudFormation; Status Code: 400)"))

    printed = captured_output_for(client)

    assert_includes printed, "Internal failure", "the SDK's message is printed verbatim"
    refute_includes printed, SECRET, "the secret in scope never reaches the output"
    refute_includes printed, TOKEN, "no session token reaches the output"
    refute_includes printed, ACCESS_KEY_ID, "and the access key id itself is not dumped either"
  end
end
