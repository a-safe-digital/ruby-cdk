# frozen_string_literal: true

require "support/deploy_fixtures"

# Shared by the ported deploy-stack.test.ts and destroy.test.ts scenarios
# (test/cdk/cli/). What the ports need over DeployFixtures:
#
#   - the two templates of the origin's harness: the stack artifact is
#     deployed with target_template (defaultTargetTemplate), and the stack
#     CloudFormation already holds is given the start template
#     (defaultStartTemplate), so "template did not change" and "template
#     changed" are decided the same way they are there;
#   - the given* functions of deploy-stack.test.ts, over the fake of
#     lib/ruby_cdk/deploy/fakes.rb: a stack that exists, a template of its
#     own, and the setup where the deploy would be skipped;
#   - the origin's default stack (FAKE_STACK), named withouterrors.
#
# The CDK's harness answers its approval questions by itself; an unattended
# deploy of a stack without env here needs --account (D-026), so every deploy
# carries yes: true and the account (unattended, from DeployFixtures).
module CdkDeploy
  include DeployFixtures

  # The stack the origin deploys by default (FAKE_STACK, testStack({ stackName:
  # 'withouterrors' })).
  STACK_NAME = "withouterrors"

  # defaultStartTemplate(): what CloudFormation holds before the deploy.
  def start_template
    template(
      resources: { "MyResource" => { "Type" => "Test::Resource::Type", "Properties" => { "Foo" => "Foo" } } },
      "Description" => "Default start template in deploy-stack.test.ts"
    )
  end

  # defaultTargetTemplate(): the template of the stack artifact, what a deploy
  # sends.
  def target_template
    template(
      resources: { "MyResource" => { "Type" => "Test::Resource::Type", "Properties" => { "Bar" => "Bar" } } },
      "Description" => "Default start template in deploy-stack.test.ts"
    )
  end

  # The template of FAKE_STACK_WITH_PARAMETERS: one parameter with a value to
  # give, one with a default, one more that must be given.
  def parameters_template
    JSON.generate({
      "Parameters" => {
        "HasValue" => { "Type" => "String" },
        "HasDefault" => { "Type" => "String", "Default" => "TheDefault" },
        "OtherParameter" => { "Type" => "String" }
      }
    })
  end

  # The origin's testStack(): a stack with a name and no env.
  def cdk_stack(name: STACK_NAME, **options)
    DeployFixtures::Stack.new(stack_name: name, **options)
  end

  # givenStackExists(): the stack is there, stable, deployed with the start
  # template unless the test gives another.
  def given_stack_exists(client, name: STACK_NAME, status: "CREATE_COMPLETE", **options)
    body = options.delete(:template) || start_template
    client.stack(name, status: status, template: body, **options)
  end

  # givenTemplateIs(): the template CloudFormation holds. Registering again
  # rebuilds the record, so the status the stack already has is carried over.
  def given_template_is(client, body, name: STACK_NAME)
    record = client.stack_record(name)
    client.stack(name, status: record&.status || "CREATE_COMPLETE", template: body)
  end

  # givenNoUpdatesAreToBePerformed(): the stack is there and already holds the
  # template the deploy would send, so every check of the skip rule agrees.
  def given_no_updates_are_to_be_performed(client, name: STACK_NAME)
    given_stack_exists(client, name: name)
    given_template_is(client, target_template, name: name)
  end
end
