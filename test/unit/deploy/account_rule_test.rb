# frozen_string_literal: true

require "test_helper"
require_relative "../../support/deploy_fixtures"

# The account rule of architecture section 13. A stack with an env deploys only
# there; --account is an optional assertion; an unattended deploy of a stack
# without env needs --account. Nothing falls back: every mismatch is refused
# before a single request is made, and the target is shown before the first one.
class DeployAccountRuleTest < Minitest::Test
  include DeployFixtures
  D = RubyCdk::Deploy

  def test_a_stack_with_an_env_deploys_when_the_credentials_are_for_that_env
    client = D::Fakes::CfnClient.new
    out = D::Fakes::Output.new

    result = deploy(client, out, stack: Stack.new(env: Env.new(account: ACCOUNT, region: REGION)), options: D::DeployOptions.new(yes: true))

    assert_equal :deployed, result.outcome
    assert_equal [ { account: ACCOUNT, region: REGION, profile: nil } ], out.targets
  end

  def test_a_stack_with_an_env_refuses_credentials_for_another_account
    client = D::Fakes::CfnClient.new
    out = D::Fakes::Output.new

    error = assert_raises(D::TargetMismatch) do
      deploy(client, out, stack: Stack.new(env: Env.new(account: OTHER_ACCOUNT, region: REGION)), options: unattended)
    end

    assert_equal 1, D.exit_code_for(error)
    assert_match(/credentials are for account #{ACCOUNT}/, error.message)
    assert_match(/stack blog has env #{OTHER_ACCOUNT}\/#{REGION}/, error.message)
    assert_match(/--profile NAME/, error.message)
    assert_empty client.calls, "nothing is asked of AWS"
    assert_empty out.targets, "a refused target is not shown as if it were going to be used"
  end

  def test_a_stack_with_an_env_refuses_a_client_for_another_region
    client = D::Fakes::CfnClient.new
    out = D::Fakes::Output.new

    error = assert_raises(D::TargetMismatch) do
      deploy(client, out, stack: Stack.new(env: Env.new(account: ACCOUNT, region: OTHER_REGION)), options: unattended)
    end

    assert_equal 1, D.exit_code_for(error)
    assert_match(/client is for region #{REGION}/, error.message)
    assert_match(/env #{ACCOUNT}\/#{OTHER_REGION}/, error.message)
    assert_match(/--region #{OTHER_REGION}/, error.message)
    assert_empty client.calls
  end

  def test_account_that_matches_the_credentials_is_accepted
    client = D::Fakes::CfnClient.new
    out = D::Fakes::Output.new(approvals: true)

    result = deploy(client, out, options: D::DeployOptions.new(account: ACCOUNT))

    assert_equal :deployed, result.outcome
  end

  def test_account_that_names_another_account_is_refused
    client = D::Fakes::CfnClient.new
    out = D::Fakes::Output.new

    error = assert_raises(D::AccountMismatch) do
      deploy(client, out, options: D::DeployOptions.new(account: OTHER_ACCOUNT))
    end

    assert_equal 1, D.exit_code_for(error)
    assert_match(/--account #{OTHER_ACCOUNT} was given/, error.message)
    assert_match(/credentials are for account #{ACCOUNT}/, error.message)
    assert_match(/--account #{ACCOUNT}/, error.message)
    assert_empty client.calls
    assert_empty out.targets
  end

  def test_account_is_an_assertion_even_for_a_stack_with_an_env
    client = D::Fakes::CfnClient.new

    assert_raises(D::AccountMismatch) do
      deploy(client, stack: Stack.new(env: Env.new(account: ACCOUNT, region: REGION)), options: D::DeployOptions.new(account: OTHER_ACCOUNT))
    end
    assert_empty client.calls
  end

  def test_an_unattended_deploy_of_a_stack_without_env_needs_account
    client = D::Fakes::CfnClient.new
    out = D::Fakes::Output.new

    error = assert_raises(D::AccountRequired) { deploy(client, out, options: D::DeployOptions.new(yes: true)) }

    assert_kind_of RubyCdk::UsageError, error
    assert_equal 1, D.exit_code_for(error)
    assert_match(/unattended deploy \(--yes\).*stack blog.*no env.*--account/, error.message)
    assert_match(/--account #{ACCOUNT}/, error.message, "the account to write down is named")
    assert_empty client.calls
    assert_empty out.targets
  end

  def test_an_unattended_deploy_of_a_stack_with_an_env_needs_no_account
    client = D::Fakes::CfnClient.new

    result = deploy(client, stack: Stack.new(env: Env.new(account: ACCOUNT, region: REGION)), options: D::DeployOptions.new(yes: true))

    assert_equal :deployed, result.outcome
  end

  def test_an_attended_deploy_of_a_stack_without_env_needs_no_account
    client = D::Fakes::CfnClient.new
    out = D::Fakes::Output.new(approvals: true)

    result = deploy(client, out, options: D::DeployOptions.new)

    assert_equal :deployed, result.outcome, "the approval is the checkpoint"
  end

  def test_no_identity_is_refused
    [ nil, D::Identity.new(account: nil, region: REGION, arn: nil), identity(account: "") ].each do |who|
      client = D::Fakes::CfnClient.new
      out = D::Fakes::Output.new

      error = assert_raises(D::AccountUnresolved, who.inspect) { deploy(client, out, options: unattended, identity: who) }

      assert_equal 1, D.exit_code_for(error)
      assert_empty client.calls
    end
  end

  def test_the_target_is_shown_before_anything_else_with_the_account_whole
    client = D::Fakes::CfnClient.new
    out = D::Fakes::Output.new

    deploy(client, out, options: D::DeployOptions.new(yes: true, account: ACCOUNT, profile: "work"))

    assert_equal :target, out.calls.first.operation
    assert_equal [ { account: ACCOUNT, region: REGION, profile: "work" } ], out.targets
  end

  def test_destroy_refuses_an_account_that_does_not_match_and_shows_the_target
    client = D::Fakes::CfnClient.new
    client.stack("blog")

    out = D::Fakes::Output.new
    assert_raises(D::AccountMismatch) { destroy(client, out, options: D::DeployOptions.new(yes: true, account: OTHER_ACCOUNT)) }
    assert_empty client.calls

    out = D::Fakes::Output.new
    assert_raises(D::AccountUnresolved) { destroy(client, out, options: D::DeployOptions.new(yes: true), identity: nil) }
    assert_empty client.calls

    destroy(client, out, stack: Stack.new(stack_name: "blog", env: Env.new(account: ACCOUNT, region: REGION)),
      options: D::DeployOptions.new(yes: true))
    assert_equal [ { account: ACCOUNT, region: REGION, profile: nil } ], out.targets
  end

  def test_destroy_holds_the_whole_account_rule_of_a_stack_with_an_env
    client = D::Fakes::CfnClient.new
    client.stack("blog")

    assert_raises(D::TargetMismatch) do
      destroy(client, stack: Stack.new(stack_name: "blog", env: Env.new(account: OTHER_ACCOUNT, region: REGION)),
        options: unattended)
    end
    assert_empty client.calls, "a destroy in the wrong account never reaches AWS"

    assert_raises(D::AccountRequired) do
      destroy(client, stack: Stack.new(stack_name: "blog", env: nil), options: D::DeployOptions.new(yes: true))
    end
    assert_empty client.calls, "an unattended destroy of a stack without env names its account first"

    out = D::Fakes::Output.new
    result = destroy(client, out, stack: Stack.new(stack_name: "blog", env: Env.new(account: ACCOUNT, region: REGION)),
      options: D::DeployOptions.new(yes: true))

    assert_equal :destroyed, result.outcome
    assert_equal "DELETE_COMPLETE", client.stack_record("blog").status
  end
end
