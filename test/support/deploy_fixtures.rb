# frozen_string_literal: true

require "ruby_cdk/deploy/fakes"

# What the deploy tests share: a stand-in for a stack, a template, an identity,
# and an engine that never waits.
#
# The stand-ins are deliberately not the real RubyCdk::Stack and RubyCdk::Env:
# the engine may depend on neither, only on the four methods it reads, and a
# test should show that it reads no more.
module DeployFixtures
  ACCOUNT = "111122223333"
  OTHER_ACCOUNT = "999988887777"
  REGION = "eu-west-1"
  OTHER_REGION = "us-east-1"

  # A target, as the engine sees it.
  Env = Struct.new(:account, :region, keyword_init: true)

  # A stack, as the engine sees it.
  Stack = Struct.new(:stack_name, :env, :termination_protection, :tags, keyword_init: true) do
    def initialize(stack_name: "blog", env: nil, termination_protection: false, tags: {})
      super
    end
  end

  BUCKET = { "Type" => "AWS::S3::Bucket" }.freeze
  TEMPLATE = JSON.generate({ "Resources" => { "Bucket" => BUCKET } }).freeze
  CHANGE_SET_ID = "arn:aws:cloudformation:eu-west-1:111122223333:changeSet/ruby-cdk-deploy-change-set/1"

  def identity(account: ACCOUNT, region: REGION)
    RubyCdk::Deploy::Identity.new(account: account, region: region, arn: "arn:aws:iam::#{account}:user/deployer")
  end

  # A template with the given resources (by logical ID), and the other sections
  # by name: template(resources: { "Role" => ... }, "Parameters" => { ... }).
  def template(resources:, **sections)
    JSON.generate({ "Resources" => resources }.merge(sections.transform_keys(&:to_s)))
  end

  # An unattended deploy, with the account written down as the rule asks for a
  # stack that has no env.
  def unattended(**options)
    RubyCdk::Deploy::DeployOptions.new(yes: true, account: ACCOUNT, **options)
  end

  # An engine whose polls never wait. output records what the engine says.
  def engine(client, output = RubyCdk::Deploy::Fakes::Output.new, **options)
    RubyCdk::Deploy::Deployer.new(
      client: client,
      store: RubyCdk::Deploy::Fakes::ObjectStore.new,
      output: output,
      poller: RubyCdk::Deploy::Poller.instant,
      operation_poller: RubyCdk::Deploy::Poller.instant,
      **options
    )
  end

  def deploy(client, output = RubyCdk::Deploy::Fakes::Output.new, stack: Stack.new, body: TEMPLATE,
    options: RubyCdk::Deploy::DeployOptions.new, identity: client.identity, **engine_options)
    engine(client, output, **engine_options).deploy(stack: stack, template: body, identity: identity, options: options)
  end

  def destroy(client, output = RubyCdk::Deploy::Fakes::Output.new, stack_name: "blog",
    options: RubyCdk::Deploy::DeployOptions.new, identity: client.identity, **engine_options)
    engine(client, output, **engine_options).destroy(stack_name: stack_name, identity: identity, options: options)
  end

  # A change set as CloudFormation describes one. changes is :one, :none or a list.
  def change_set(status: "CREATE_COMPLETE", status_reason: nil, execution_status: "AVAILABLE", changes: :one, id: CHANGE_SET_ID)
    list = changes == :one ? [ change ] : changes == :none ? [] : changes
    RubyCdk::Deploy::ChangeSet.new(id: id, status: status, status_reason: status_reason, execution_status: execution_status,
      changes: list)
  end

  def change(action: "Add", logical_id: "Bucket", resource_type: "AWS::S3::Bucket", replacement: "False", detail: nil)
    RubyCdk::Deploy::Change.new(action: action, logical_id: logical_id, resource_type: resource_type, replacement: replacement,
      detail: detail)
  end

  # A scripted answer for describe_change_set that carries the change set ID the
  # engine was given, so that a description and the execution of the same change
  # set agree. Use it with client.on(:describe_change_set, described(status: "FAILED")).
  def described(**options)
    lambda { |call|
      change_set(id: call.args[1], **options)
    }
  end

  # A stack event. Without a time it is a second after the previous one made.
  def event(resource_status, logical_id: "blog", resource_type: nil, status_reason: nil, timestamp: nil)
    @events_made = (@events_made || 0) + 1
    RubyCdk::Deploy::Event.new(
      resource_status: resource_status,
      logical_id: logical_id,
      resource_type: resource_type || (logical_id == "blog" ? "AWS::CloudFormation::Stack" : "AWS::S3::Bucket"),
      status_reason: status_reason,
      timestamp: timestamp || Time.utc(2026, 1, 1) + @events_made
    )
  end
end
