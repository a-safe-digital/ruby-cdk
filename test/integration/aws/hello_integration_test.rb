# frozen_string_literal: true

# The Wave 1 scenario over real CloudFormation in the sandbox (WF-5, and the
# wave's gate: synth, deploy, deploy again with nothing changed, destroy, and
# the audit that shows nothing left). Written to be run by `rake integration`
# after the owner's approval for the wave; no agent runs it.

require_relative "../runner"
require_relative "hello"

class HelloIntegrationTest < Minitest::Test
  def test_hello_deploys_twice_and_destroys_clean
    Integration::Aws.hello
  end
end
