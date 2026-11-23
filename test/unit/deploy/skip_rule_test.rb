# frozen_string_literal: true

require "test_helper"
require "fileutils"
require_relative "../../support/deploy_fixtures"

# Unchanged means skipped, as in the CDK (architecture section 9): when the stack
# is stable and its deployed template, parameters and tags equal the local ones,
# no change set is created and the outputs are printed. --force deploys anyway,
# and --no-execute always creates a change set.
class DeploySkipRuleTest < Minitest::Test
  include DeployFixtures
  D = RubyCdk::Deploy

  OUTPUTS = { "Url" => "https://example.invalid" }.freeze
  SKIPPED = %i[stack_state stack_info get_template stack_parameters stack_tags].freeze

  # A client whose stack was deployed with the template and is stable.
  def deployed(body: TEMPLATE, parameters: {}, tags: [])
    client = D::Fakes::CfnClient.new
    client.stack("blog", template: body, parameters: parameters, tags: tags, outputs: OUTPUTS)
    client
  end

  def test_an_unchanged_stack_is_skipped_and_its_outputs_are_printed
    client = deployed
    out = D::Fakes::Output.new

    result = deploy(client, out, options: unattended)

    assert_equal :no_changes, result.outcome
    assert_equal 0, result.exit_code
    assert_equal client.stack_record("blog").id, result.stack_id
    assert_equal OUTPUTS, result.outputs
    assert_equal SKIPPED, client.operations
    assert_equal [ OUTPUTS ], out.shown_outputs
    assert_empty out.questions
  end

  def test_force_deploys_an_unchanged_stack_anyway
    client = deployed

    result = deploy(client, options: unattended(force: true))

    assert_equal :deployed, result.outcome
    assert_equal :update, client.kwargs_of(:create_change_set).first[:change_set_type]
    refute_includes client.operations, :get_template, "a forced deploy does not even look"
  end

  def test_no_execute_always_creates_a_change_set
    client = deployed

    result = deploy(client, options: unattended(no_execute: true))

    assert_equal :not_executed, result.outcome
    assert_equal 1, client.calls_to(:create_change_set).length
  end

  def test_a_changed_template_is_deployed
    client = deployed(body: template(resources: { "Bucket" => BUCKET.merge("Properties" => { "BucketName" => "other" }) }))

    result = deploy(client, options: unattended)

    assert_equal :deployed, result.outcome
    assert_equal 1, client.calls_to(:create_change_set).length
  end

  def test_changed_parameters_are_deployed_and_unchanged_ones_are_not
    body = template(resources: { "Bucket" => BUCKET.merge("Properties" => { "BucketName" => { "Ref" => "Name" } }) },
      "Parameters" => { "Name" => { "Type" => "String", "Default" => "a" } })

    same = deployed(body: body, parameters: { "Name" => "a" })
    assert_equal :no_changes, deploy(same, body: body, options: unattended(parameters: { "Name" => "a" })).outcome

    other = deployed(body: body, parameters: { "Name" => "a" })
    assert_equal :deployed, deploy(other, body: body, options: unattended(parameters: { "Name" => "b" })).outcome
  end

  def test_changed_tags_are_deployed
    client = deployed(tags: [ { key: "Team", value: "a" } ])

    assert_equal :no_changes, deploy(client, stack: Stack.new(tags: { "Team" => "a" }), options: unattended).outcome

    client = deployed(tags: [ { key: "Team", value: "a" } ])
    result = deploy(client, stack: Stack.new(tags: { "Team" => "b" }), options: unattended)
    assert_equal :deployed, result.outcome
    assert_equal [ { key: "Team", value: "b" } ], client.kwargs_of(:create_change_set).first[:tags]
  end

  def test_the_tags_of_the_command_sit_on_top_of_the_stack_s_own
    deployed_tags = [ { key: "Team", value: "a" }, { key: "Cost", value: "x" } ]
    stack = Stack.new(tags: { "Team" => "a", "Cost" => "x" })

    assert_equal :no_changes, deploy(deployed(tags: deployed_tags), stack: stack, options: unattended).outcome

    client = deployed(tags: deployed_tags)
    result = deploy(client, stack: stack, options: unattended(tags: { "Cost" => "y" }))

    assert_equal :deployed, result.outcome
    sent = client.kwargs_of(:create_change_set).first[:tags].sort_by { |tag| tag[:key] }
    assert_equal [ { key: "Cost", value: "y" }, { key: "Team", value: "a" } ], sent
  end

  def test_a_tag_the_stack_no_longer_declares_is_a_change
    client = deployed(tags: [ { key: "Team", value: "a" }, { key: "Cost", value: "x" } ])

    assert_equal :deployed, deploy(client, stack: Stack.new(tags: { "Team" => "a" }), options: unattended).outcome
  end

  def test_tags_are_taken_as_a_hash_as_pairs_or_as_nothing
    client = deployed(tags: [ { key: "Team", value: "a" } ])
    assert_equal :no_changes, deploy(client, stack: Stack.new(tags: [ [ "Team", "a" ] ]), options: unattended).outcome,
      "written as pairs"

    client = deployed
    assert_equal :no_changes, deploy(client, stack: Stack.new(tags: nil), options: unattended).outcome, "or as nothing"

    client = deployed
    result = deploy(client, stack: Stack.new(tags: [ [ "Team", "b" ] ]), options: unattended)
    assert_equal :deployed, result.outcome
    assert_equal [ { key: "Team", value: "b" } ], client.kwargs_of(:create_change_set).first[:tags]
  end

  def test_a_template_deployed_as_yaml_is_not_trusted_to_be_unchanged
    client = deployed(body: "Resources:\n  Bucket:\n    Type: AWS::S3::Bucket\n")

    result = deploy(client, options: unattended)

    assert_equal :deployed, result.outcome, "the change set is created, and CloudFormation is asked"
  end

  def test_a_deployed_template_that_is_not_json_at_all_is_not_trusted
    [ "{not json", nil, "" ].each do |body|
      client = deployed(body: body)

      assert_equal :deployed, deploy(client, options: unattended).outcome, body.inspect
    end
  end

  def test_key_order_and_whitespace_do_not_make_a_template_different
    client = deployed(body: "{\n  \"Resources\" : { \"Bucket\" : {\"Type\" : \"AWS::S3::Bucket\" } }\n}\n")

    result = deploy(client, options: unattended)

    assert_equal :no_changes, result.outcome
  end

  def test_a_parameter_resolved_by_cloud_formation_is_never_trusted
    body = template(resources: { "Bucket" => BUCKET.merge("Properties" => { "BucketName" => { "Ref" => "Name" } }) },
      "Parameters" => { "Name" => { "Type" => "AWS::SSM::Parameter::Value<String>" } })
    client = deployed(body: body, parameters: { "Name" => "/x" })

    result = deploy(client, body: body, options: unattended(parameters: { "Name" => "/x" }))

    assert_equal :deployed, result.outcome
  end

  def test_a_skipped_deploy_still_reconciles_termination_protection
    client = deployed

    result = deploy(client, stack: Stack.new(termination_protection: true), options: unattended)

    assert_equal :no_changes, result.outcome
    assert_equal [ { enabled: true } ], client.calls_to(:update_termination_protection).map(&:kwargs)
  end

  def test_a_skipped_deploy_writes_the_outputs_file
    client = deployed
    path = File.join(Dir.tmpdir, "ruby-cdk-skip-#{object_id}.json")

    deploy(client, options: unattended(outputs_file: path))
    written = File.read(path)
    FileUtils.rm_f(path)

    assert_equal "#{JSON.pretty_generate(OUTPUTS)}\n", written
  end
end
