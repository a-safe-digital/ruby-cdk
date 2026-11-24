# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/deploy"

# The parameter values a deploy sends, and whether they changed. The rule is
# the CDK's (ParameterValues in its CLI, cfn-api.ts): a value that is given
# wins, then the template's default, then the value the stack has; a parameter
# with none of the three is an error.
class DeployParametersTest < Minitest::Test
  Parameters = RubyCdk::Deploy::Parameters

  def parameters(declared, overrides = {}, deployed: nil)
    Parameters.new({ "Parameters" => declared }, overrides, deployed: deployed)
  end

  def test_a_value_that_is_given_wins_and_is_sent
    values = parameters({ "Env" => { "Type" => "String" } }, { "Env" => "prod" })

    assert_equal({ "Env" => "prod" }, values.values)
    assert_equal [ { parameter_key: "Env", parameter_value: "prod" } ], values.api
  end

  def test_the_default_is_used_and_not_sent
    values = parameters({ "Size" => { "Type" => "Number", "Default" => 5 } })

    assert_equal({ "Size" => "5" }, values.values)
    assert_equal [], values.api, "a parameter left to its default is not sent, as in the CDK"
  end

  def test_a_given_value_beats_the_default
    values = parameters({ "Size" => { "Type" => "Number", "Default" => 5 } }, { "Size" => 10 })

    assert_equal({ "Size" => "10" }, values.values)
    assert_equal [ { parameter_key: "Size", parameter_value: "10" } ], values.api
  end

  def test_a_parameter_with_neither_a_value_nor_a_default_is_an_error
    error = assert_raises(RubyCdk::Deploy::ParametersMissing) do
      parameters({ "Env" => { "Type" => "String" }, "Size" => { "Type" => "Number", "Default" => 1 }, "Name" => { "Type" => "String" } })
    end

    assert_match(/missing a value: Env, Name/, error.message)
    assert_match(/--parameters Env=<value> Name=<value>/, error.message)
    assert_equal 1, RubyCdk::Deploy.exit_code_for(error)
  end

  def test_keys_are_stretched_to_strings_whatever_they_were_written_as
    values = parameters({ "Count" => { "Type" => "Number" }, "on" => { "Type" => "String" } }, { "Count" => 3, on: true })

    assert_equal({ "Count" => "3", "on" => "true" }, values.values)
    assert_equal [ { parameter_key: "Count", parameter_value: "3" }, { parameter_key: "on", parameter_value: "true" } ], values.api
  end

  def test_a_list_is_sent_as_one_comma_separated_string
    values = parameters({ "Zones" => { "Type" => "CommaDelimitedList" } }, { "Zones" => [ "a", "b" ] })

    assert_equal({ "Zones" => "a,b" }, values.values)
    assert_equal "a,b", values.api.first[:parameter_value]
  end

  def test_a_value_for_a_parameter_the_template_does_not_declare_is_passed_on
    values = parameters({ "Env" => { "Type" => "String" } }, { "Env" => "prod", "Typo" => "x", "Empty" => "" })

    assert_equal [ { parameter_key: "Env", parameter_value: "prod" }, { parameter_key: "Typo", parameter_value: "x" } ], values.api
    assert_equal "x", values.values["Typo"], "CloudFormation reports the typo, as in the CDK"
  end

  def test_a_template_without_parameters_takes_none
    values = Parameters.new(JSON.parse("{}"), {})

    assert_equal({}, values.values)
    assert_equal [], values.api
    assert_equal false, values.changes?({})
  end

  # --- has anything changed

  def test_the_same_values_mean_no_change
    values = parameters({ "Env" => { "Type" => "String" }, "Size" => { "Type" => "Number", "Default" => 5 } }, { "Env" => "prod" })

    assert_equal false, values.changes?({ "Env" => "prod", "Size" => "5" })
  end

  def test_a_changed_a_new_or_a_removed_value_means_a_change
    values = parameters({ "Env" => { "Type" => "String" } }, { "Env" => "prod" })

    assert_equal true, values.changes?({ "Env" => "dev" }), "changed"
    assert_equal true, values.changes?({ "Env" => "prod", "Old" => "x" }), "removed from the template"
    assert_equal true, values.changes?({}), "new"
    assert_equal true, values.changes?(nil), "nothing deployed"
  end

  def test_an_ssm_parameter_can_change_with_no_local_sign_of_it
    values = parameters({ "Arn" => { "Type" => "AWS::SSM::Parameter::Value<String>" } }, { "Arn" => "/x" })

    assert values.resolved_by_cloud_formation?
    assert_equal true, values.changes?({ "Arn" => "/x" }), "a deploy is never skipped on an SSM parameter, even unchanged"
  end

  def test_an_ordinary_parameter_is_known_locally
    assert_equal false, parameters({ "Env" => { "Type" => "String", "Default" => "dev" } }).resolved_by_cloud_formation?
  end

  # A parameter that is not given again keeps the value the stack has, as the
  # CDK sends it (UsePreviousValue): the masked value of a NoEcho parameter is
  # not comparable with the real one, and goes back as it came.
  def test_a_parameter_without_a_value_or_a_default_keeps_the_deployed_one
    values = parameters({ "Env" => { "Type" => "String" } }, {}, deployed: { "Env" => "****" })

    assert_equal({ "Env" => "****" }, values.values)
    assert_equal [ { parameter_key: "Env", use_previous_value: true } ], values.api
    assert_equal false, values.changes?({ "Env" => "****" }), "the masked value compares equal to itself"
  end

  def test_a_given_value_beats_the_deployed_one
    values = parameters({ "Env" => { "Type" => "String" } }, { "Env" => "prod" }, deployed: { "Env" => "****" })

    assert_equal({ "Env" => "prod" }, values.values)
    assert_equal [ { parameter_key: "Env", parameter_value: "prod" } ], values.api
    assert values.changes?({ "Env" => "****" })
  end

  def test_the_default_beats_the_deployed_value
    values = parameters({ "Size" => { "Type" => "Number", "Default" => 5 } }, {}, deployed: { "Size" => "9" })

    assert_equal({ "Size" => "5" }, values.values)
    assert_equal [], values.api, "a default is not sent"
    assert values.changes?({ "Size" => "9" }), "and the stack is told that the default differs from what it has"
  end

  def test_a_parameter_missing_without_a_deployed_value_is_still_an_error
    assert_raises(RubyCdk::Deploy::ParametersMissing) do
      parameters({ "Env" => { "Type" => "String" } }, {}, deployed: { "Other" => "x" })
    end
  end
end
