# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/deploy"

# Every signature of the architecture contract compiles on this Ruby and has
# the stated parameters. When a signature must change, the architecture document
# changes in the same commit.
class ContractTest < Minitest::Test
  def assert_parameter(owner, method, name, kind = nil)
    parameters = owner.instance_method(method).parameters
    index = parameters.index { |_, parameter| parameter == name }

    assert index, "#{owner}##{method} has no parameter #{name}; it has #{parameters.map(&:last).inspect}"
    assert_equal kind, parameters[index].first if kind
  end

  def test_construct_resource_takes_properties_as_keywords_or_one_explicit_hash
    assert_parameter RubyCdk::Construct, :resource, :id, :req
    assert_parameter RubyCdk::Construct, :resource, :type, :req
    assert_parameter RubyCdk::Construct, :resource, :properties, :key
    assert_parameter RubyCdk::Construct, :resource, :depends_on, :key
    assert_parameter RubyCdk::Construct, :resource, :condition, :key
    assert_parameter RubyCdk::Construct, :resource, :deletion_policy, :key
    assert_parameter RubyCdk::Construct, :resource, :update_replace_policy, :key
    assert_parameter RubyCdk::Construct, :resource, :metadata, :key
    assert_parameter RubyCdk::Construct, :resource, :opts, :keyrest
  end

  def test_fn_is_reachable_from_any_construct
    assert_same RubyCdk::Fn, RubyCdk::Construct::Fn
  end

  # Every function of the CDK's Fn (core/lib/cfn-fn.ts) that this tool carries,
  # minus the CDK's internal helpers (minimal_join). When a function is added
  # or dropped, the architecture's section 3 changes in the same commit.
  def test_fn_has_the_functions_of_the_contract
    %i[ref get_att sub join select split base64 import_value import_list_value get_azs find_in_map if equals and_ or_ not_
       parse_domain_name cidr get_stack_output transform to_json_string len ref_all value_of value_of_all contains
       each_member_equals each_member_in].each do |name|
      assert_respond_to RubyCdk::Fn, name
    end
    assert_equal({ "Ref" => "AWS::NoValue" }, RubyCdk::Fn::NO_VALUE)
  end

  def test_app
    assert_respond_to RubyCdk::App, :current
    assert_respond_to RubyCdk::App, :build!

    %i[env out_dir stack_name_prefix stateful_default].each do |name|
      assert_parameter RubyCdk::App, :initialize, name, :key
    end
    assert_parameter RubyCdk::App, :initialize, :block, :block
    assert RubyCdk::App.method_defined?(:synth)
  end

  def test_stack
    %i[env description tags stateful_default termination_protection].each do |name|
      assert_parameter RubyCdk::Stack, :initialize, name, :key
    end
    assert_parameter RubyCdk::Stack, :initialize, :block, :block

    %i[output export export_name mapping condition asset unique_name add_dependency to_template stack_name termination_protection].each do |name|
      assert RubyCdk::Stack.method_defined?(name), "Stack##{name} is missing"
    end

    assert_parameter RubyCdk::Stack, :parameter, :type, :keyreq
    assert_parameter RubyCdk::Stack, :parameter, :allowed_values, :key
    assert_parameter RubyCdk::Stack, :parameter, :no_echo, :key
    assert_parameter RubyCdk::Stack, :output, :value, :keyreq
    assert_parameter RubyCdk::Stack, :output, :export, :key
    assert_parameter RubyCdk::Stack, :output, :condition, :key
    assert_parameter RubyCdk::Stack, :export, :value, :keyreq
    assert_parameter RubyCdk::Stack, :unique_name, :max_length, :key
  end

  def test_fn_renders_every_intrinsic
    # The name list lives in test_fn_has_the_functions_of_the_contract, above.
    assert_equal({ "Ref" => "AWS::NoValue" }, RubyCdk::Fn::NO_VALUE)
  end

  def test_lazy_env_and_assets
    assert_parameter RubyCdk::Lazy, :initialize, :block, :block
    assert_parameter RubyCdk::Lazy, :resolve, :stack, :req

    assert_parameter RubyCdk::Env, :initialize, :account, :keyreq
    assert_parameter RubyCdk::Env, :initialize, :region, :keyreq

    assert_parameter RubyCdk::Assets::Builder, :initialize, :stack, :req
    assert_parameter RubyCdk::Assets::Builder, :zip, :path, :req
    assert_parameter RubyCdk::Assets::Builder, :zip, :exclude, :key
    # Not hash: Object#hash must answer an Integer, so an asset could not be a Hash key.
    %i[asset_hash key bucket s3_location].each do |name|
      assert RubyCdk::Assets::Zip.method_defined?(name), "Assets::Zip##{name} is missing"
    end
  end

  def test_deploy_structs
    assert_equal %i[id status status_reason execution_status changes], RubyCdk::Deploy::ChangeSet.members
    assert_equal %i[action logical_id resource_type replacement detail], RubyCdk::Deploy::Change.members
    assert_equal %i[resource_status logical_id resource_type status_reason timestamp], RubyCdk::Deploy::Event.members
    assert_equal %i[logical_id status physical_id], RubyCdk::Deploy::StackResource.members
    assert_equal %i[account region arn], RubyCdk::Deploy::Identity.members
    assert_equal %i[name id status outputs termination_protection], RubyCdk::Deploy::StackInfo.members
    assert_equal %i[name id status], RubyCdk::Deploy::ListedStack.members
    assert_equal %i[absent review stable rollback_complete rollback_failed busy], RubyCdk::Deploy::STACK_STATES
  end

  def test_deploy_ports
    %i[target changes ask confirm event outputs failure retained announce].each do |name|
      assert RubyCdk::Deploy::Output.method_defined?(name), "Output##{name} is missing"
    end

    %i[resolve_identity stack_state stack_info stack_parameters stack_tags list_stacks create_change_set describe_change_set
       execute_change_set delete_change_set delete_stack list_resources events get_template update_termination_protection
       operation_events].each do |name|
      assert RubyCdk::Deploy::CfnClient.method_defined?(name), "CfnClient##{name} is missing"
    end
    assert_parameter RubyCdk::Deploy::CfnClient, :create_change_set, :template, :keyreq
    assert_parameter RubyCdk::Deploy::CfnClient, :create_change_set, :on_stack_failure, :key
    assert_parameter RubyCdk::Deploy::CfnClient, :execute_change_set, :retain_except_on_create, :key
    assert_parameter RubyCdk::Deploy::CfnClient, :events, :after, :keyreq
    assert_parameter RubyCdk::Deploy::CfnClient, :update_termination_protection, :enabled, :keyreq

    %i[bucket_state object_exists? put].each do |name|
      assert RubyCdk::Deploy::ObjectStore.method_defined?(name), "ObjectStore##{name} is missing"
    end
    assert_parameter RubyCdk::Deploy::ObjectStore, :bucket_state, :expected_owner, :keyreq
    assert_parameter RubyCdk::Deploy::ObjectStore, :object_exists?, :expected_owner, :keyreq
    assert_parameter RubyCdk::Deploy::ObjectStore, :put, :expected_owner, :keyreq
  end

  def test_deployer
    %i[client store output].each { |name| assert_parameter RubyCdk::Deploy::Deployer, :initialize, name, :keyreq }
    %i[stack template identity options].each { |name| assert_parameter RubyCdk::Deploy::Deployer, :deploy, name, :keyreq }
    %i[stack_name identity options].each { |name| assert_parameter RubyCdk::Deploy::Deployer, :destroy, name, :keyreq }

    %i[deployed no_changes not_executed rejected failed].each do |outcome|
      assert_includes RubyCdk::Deploy::DeployResult::OUTCOMES, outcome
    end
    assert_raises(ArgumentError) { RubyCdk::Deploy::DeployResult.new(stack_name: "s", outcome: :nonsense) }
  end
end
