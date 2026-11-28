# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/@aws-cdk/toolkit-lib/test/api/hotswap/lambda-functions-hotswap-deployments.test.ts
#            and packages/@aws-cdk/toolkit-lib/test/api/hotswap/lambda-functions-inline-hotswap-deployments.test.ts,
#            in aws/aws-cdk-cli
#   Commit:  f7c9dca95f440a076c2abd61b66b984624b8548e (main, read on 2026-11-28)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The two origins hold 22 test declarations inside a describe.each over the
# two hotswap modes (fall-back, hotswap-only): 44 cases. Each ported one keeps
# its name, as a comment above the test, and what it expects. The scenarios
# there run tryHotswapDeployment() against a mock Lambda client and a mock
# CloudFormation; here they run Deployer#deploy with --hotswap and
# --hotswap-fallback against the scripted fake of lib/ruby_cdk/deploy/fakes.rb,
# through DeployFixtures (the stack CloudFormation holds is registered with
# client.stack, the template the deploy sends is the body).
#
# Changed, with nothing else in a scenario, an input or an outcome:
#   - The origin applies each hotswappable function with the Lambda SDK
#     (UpdateFunctionCode, UpdateFunctionConfiguration) and asserts the
#     commands it received; the engine applies through one CloudFormation
#     UpdateStack that carries the whole new template, so
#     toHaveReceivedCommandWith(X, Y) reads here as an assert on the
#     update_stack request whose template carries Y's new values, and on the
#     result's hotswap facts.
#   - The origin's undefined (fall-back refused) reads here as the change-set
#     deploy that follows, and its SuccessfulDeployStackResult as a
#     DeployResult with outcome :deployed; a hotswap-only deploy that applies
#     nothing answers :no_changes, which is the origin's noOp result.
#   - The origins run every declaration twice, once per mode; so does this
#     file, through each_mode, unless a scenario's two runs differ (the origin
#     branches on the mode inside the test, and so does the port).
#
# Ported with an expectation changed, where this tool differs by design, said
# next to the expectation:
#   - a function name the template builds from a reference: the origin resolves
#     it for the API call (and falls back to the stack's physical name through
#     ListStackResources when it cannot); the engine evaluates no intrinsics
#     and lists no resources -- CloudFormation resolves the template whole, and
#     the report names the logical ID (section 21).
#   - a mixed change, a code difference and a non-hotswappable one together:
#     the origin hotswaps the hotswappable half in hotswap-only mode and leaves
#     the rest as drift; the engine applies nothing in either mode -- one
#     UpdateStack carries the whole template, and a partial one would delete
#     every resource it leaves out (section 21).
#   - inline code: the origin zips ZipFile for node and python runtimes only
#     and refuses any other; CloudFormation takes ZipFile for every runtime,
#     so the template goes as written (section 21).
#
# Not ported, with the reason:
#
#   The fast path here evaluates no intrinsics (section 21), which these need
#   to classify:
#   - will not perform a hotswap deployment if it cannot find a Ref target
#     (outside the function's name): the origin refuses with a
#     CfnEvaluationException; the engine sends the template and CloudFormation
#     answers at the update.
#   - will not perform a hotswap deployment if it doesn't know how to handle a
#     specific attribute (outside the function's name): the same reason.
#   - Lambda hotswap works properly with changes of environment variables and
#     description with tokens: the origin resolves GetAtt and Fn::Join into
#     the API call; the engine sends the template whole (section 21).
#
#   The physical name of an unnamed function, which the origin reads from
#   ListStackResources:
#   - correctly falls back to taking the function's name from the current stack
#     if it can't evaluate it in the template. The ported case above holds what
#   the engine does instead: the report names the logical ID.
#
#   The Lambda SDK's waiter after each update, which this engine does not have;
#   it follows the operation through CloudFormation's events:
#   - calls waiter after function code is updated with delay 1
#   - calls waiter after function code is updated and VpcId is empty string
#     with delay 1
#   - calls getFunction() after function code is updated on a VPC function with
#     delay 5
#
#   The origin's refusal of an inline-code change on an unsupported runtime:
#   - throw a CfnEvaluationException when it receives an unsupported function
#     runtime (section 21: no runtime check here).
#
# Parity: 44 cases in the origin; 28 ported; 16 not ported; 14 tests.

require "test_helper"
require "support/deploy_fixtures"

class CdkCliHotswapTest < Minitest::Test
  include DeployFixtures
  D = RubyCdk::Deploy

  FUNCTION = "AWS::Lambda::Function"

  # The origin's STACK_NAME (hotswap-test-setup.ts: STACK_NAME = 'withouterrors').
  STACK_NAME = "withouterrors"

  # The two hotswap modes of the origin's describe.each, as this engine's
  # option sets.
  MODES = [ "fall-back", "hotswap-only" ].freeze

  # --- the harness

  def given_stack_template(client, body)
    client.stack(STACK_NAME, status: "UPDATE_COMPLETE", template: body)
  end

  # Deploys the body in one mode and then in the other, as the origin's
  # describe.each runs its cases. Yields [mode, result, output].
  def deploy_in_each_mode(client, body, options: nil)
    MODES.each do |mode|
      fresh = D::Fakes::CfnClient.new
      given_stack_template(fresh, client.stack_record(STACK_NAME).template)
      out = D::Fakes::Output.new
      chosen = options || (mode == "fall-back" ? fallback_options : hotswap_options)
      result = deploy(fresh, out, stack: DeployFixtures::Stack.new(stack_name: STACK_NAME), body: body, options: chosen)
      yield mode, result, out, fresh
    end
  end

  def hotswap_options(**options)
    unattended(hotswap: true, **options)
  end

  def fallback_options(**options)
    unattended(hotswap_fallback: true, **options)
  end

  def s3_function(bucket, key, **more)
    { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => bucket, "S3Key" => key },
      "FunctionName" => "my-function", **more } }
  end

  # test('returns undefined when a new Lambda function is added to the Stack')
  #
  # The origin branches on the mode: fall-back refuses the whole deploy, and
  # hotswap-only answers noOp without applying anything.
  def test_a_new_lambda_function_is_added_to_the_stack
    given_stack_template(client, JSON.generate({ "Resources" => {} }))
    body = JSON.generate({ "Resources" => { "Func" => { "Type" => FUNCTION } } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_empty fresh.calls_to(:update_stack), mode
      if mode == "fall-back"
        assert_equal :deployed, result.outcome, "#{mode}: the change set carries the creation"
        assert_equal 1, fresh.calls_to(:create_change_set).size
      else
        assert_equal :no_changes, result.outcome, "#{mode}: the creation is ignored"
        assert_empty fresh.calls_to(:create_change_set)
      end
    end
  end

  # test('calls the updateLambdaCode() API when it receives only a code difference in a Lambda function')
  def test_a_code_difference_updates_the_function
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => s3_function("current-bucket", "current-key") } }))
    body = JSON.generate({ "Resources" => { "Func" => s3_function("current-bucket", "new-key") } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_equal :deployed, result.outcome, mode
      request = fresh.kwargs_of(:update_stack).first
      assert_includes request[:template], "new-key", mode
      assert_includes request[:template], "my-function", mode
      assert_equal [ { logical_id: "Func", resource_type: FUNCTION, name: "my-function" } ],
        result.hotswap.swapped.map(&:to_h), mode
    end
  end

  # test('correctly evaluates the function's name when it references a different resource from the template')
  #
  # The origin resolves Fn::Join over a Ref into the physical name and sends it
  # to the Lambda API; the engine evaluates no intrinsics: CloudFormation
  # resolves the template whole, and the report names the logical ID.
  def test_a_name_the_template_builds_from_a_reference_is_reported_by_the_logical_id
    named = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "current-bucket", "S3Key" => "current-key" },
      "FunctionName" => { "Fn::Join" => [ "-", [ "lambda", { "Ref" => "Bucket" }, "function" ] ] } } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" }, "Func" => named } }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "current-bucket", "S3Key" => "new-key" },
      "FunctionName" => { "Fn::Join" => [ "-", [ "lambda", { "Ref" => "Bucket" }, "function" ] ] } } }
    body = JSON.generate({ "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" }, "Func" => renamed } })

    deploy_in_each_mode(client, body) do |mode, result, out, fresh|
      assert_equal :deployed, result.outcome, mode
      assert_includes fresh.kwargs_of(:update_stack).first[:template], "new-key", mode
      assert_includes out.announcements, "   ✨ AWS::Lambda::Function 'Func' hotswapped!", mode
    end
  end

  # test('calls the updateLambdaCode() API when it receives a code difference in a Lambda function with no name')
  #
  # The origin takes the physical name from ListStackResources; the engine
  # names the report after the logical ID and updates all the same.
  def test_a_code_difference_in_a_function_without_a_literal_name_still_updates
    unnamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "current-bucket", "S3Key" => "current-key" } } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => unnamed } }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "current-bucket", "S3Key" => "new-key" } } }
    body = JSON.generate({ "Resources" => { "Func" => renamed } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_equal :deployed, result.outcome, mode
      assert_equal [ { logical_id: "Func", resource_type: FUNCTION, name: nil } ],
        result.hotswap.swapped.map(&:to_h), mode
      assert_includes fresh.kwargs_of(:update_stack).first[:template], "new-key", mode
    end
  end

  # test('does not call the updateLambdaCode() API when it receives a change that is not a code difference in a Lambda function')
  #
  # The PackageType Zip to Image change: a property the fast path does not
  # carry. The origin expects undefined in fall-back and a noOp in
  # hotswap-only; nothing reaches the Lambda API in either.
  def test_a_change_that_is_not_a_code_or_configuration_difference_is_refused_in_both_modes
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => s3_function("current-bucket", "current-key", "PackageType" => "Zip") } }))
    body = JSON.generate({ "Resources" => { "Func" => s3_function("current-bucket", "current-key", "PackageType" => "Image") } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_empty fresh.calls_to(:update_stack), mode
      assert_empty fresh.calls_to(:create_change_set), mode unless mode == "fall-back"
      assert_empty result.hotswap.swapped, mode
      if mode == "fall-back"
        assert_equal :deployed, result.outcome, "#{mode}: the change set takes the deploy"
      else
        assert_equal :no_changes, result.outcome, mode
        assert_equal [ "Func" ], result.hotswap.non_hotswappable.map(&:logical_id), mode
      end
    end
  end

  # test('does not call the updateLambdaCode() API when a resource with type that is not AWS::Lambda::Function but has the same
  #       properties is changed')
  def test_the_same_properties_on_another_type_are_refused_in_both_modes
    not_a_function = { "Type" => "AWS::NotLambda::NotAFunction",
      "Properties" => { "Code" => { "S3Bucket" => "current-bucket", "S3Key" => "current-key" } } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => not_a_function } }))
    body = JSON.generate({ "Resources" => { "Func" => { "Type" => "AWS::NotLambda::NotAFunction",
      "Properties" => { "Code" => { "S3Bucket" => "current-bucket", "S3Key" => "new-key" } } } } })

    deploy_in_each_mode(client, body) do |mode, result, out, fresh|
      assert_empty fresh.calls_to(:update_stack), mode
      assert_includes out.announcements, "    resource: Func, type: AWS::NotLambda::NotAFunction, " \
        "reason: This resource type is not supported for hotswap deployments", mode
      if mode == "fall-back"
        assert_equal :deployed, result.outcome, mode
      else
        assert_equal :no_changes, result.outcome, mode
      end
    end
  end

  # test('when it receives a non-hotswappable change that includes a code difference in a Lambda function, it does not call the
  #       updateLambdaCode() API in CLASSIC mode but does in HOTSWAP_ONLY mode')
  #
  # Expectation changed: the engine applies nothing in either mode. One
  # UpdateStack carries the whole template, so a partial hotswap would delete
  # every resource the hotswappable half leaves out (section 21).
  def test_a_mixed_change_is_not_applied_in_part_in_either_mode
    mixed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "current-bucket", "S3Key" => "current-key" },
      "FunctionName" => "my-function", "PackageType" => "Zip" } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => mixed } }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "current-bucket", "S3Key" => "new-key" },
      "FunctionName" => "my-function", "PackageType" => "Image" } }
    body = JSON.generate({ "Resources" => { "Func" => renamed } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_empty fresh.calls_to(:update_stack), mode
      assert_empty result.hotswap.swapped, mode
      assert_equal [ "Func" ], result.hotswap.non_hotswappable.map(&:logical_id), mode
    end
  end

  # test('calls the updateLambdaConfiguration() API when it receives difference in Description field of a Lambda function')
  def test_a_description_difference_updates_the_function
    described = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "s3-bucket", "S3Key" => "s3-key" },
      "FunctionName" => "my-function", "Description" => "Old Description" } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => described } }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "s3-bucket", "S3Key" => "s3-key" },
      "FunctionName" => "my-function", "Description" => "New Description" } }
    body = JSON.generate({ "Resources" => { "Func" => renamed } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_equal :deployed, result.outcome, mode
      assert_includes fresh.kwargs_of(:update_stack).first[:template], "New Description", mode
    end
  end

  # test('calls the updateLambdaConfiguration() API when a Lambda function Description is changed to an empty string')
  #
  # The origin's regression: an empty Description is a real change and must
  # reach the update, not be read as no Description change.
  def test_a_description_changed_to_an_empty_string_updates_the_function
    described = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "s3-bucket", "S3Key" => "s3-key" },
      "FunctionName" => "my-function", "Description" => "Old Description" } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => described } }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "s3-bucket", "S3Key" => "s3-key" },
      "FunctionName" => "my-function", "Description" => "" } }
    body = JSON.generate({ "Resources" => { "Func" => renamed } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_equal :deployed, result.outcome, mode
      assert_includes fresh.kwargs_of(:update_stack).first[:template], "\"Description\":\"\"", mode
    end
  end

  # test('calls the updateLambdaConfiguration() API when it receives difference in Environment field of a Lambda function')
  def test_an_environment_difference_updates_the_function
    environment = { "Variables" => { "Key1" => "Value1", "Key2" => "Value2" } }
    described = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "s3-bucket", "S3Key" => "s3-key" },
      "FunctionName" => "my-function", "Environment" => environment } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => described } }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "s3-bucket", "S3Key" => "s3-key" },
      "FunctionName" => "my-function", "Environment" => { "Variables" => { "Key1" => "Value1", "Key2" => "Value2",
        "NewKey" => "NewValue" } } } }
    body = JSON.generate({ "Resources" => { "Func" => renamed } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_equal :deployed, result.outcome, mode
      assert_includes fresh.kwargs_of(:update_stack).first[:template], "NewValue", mode
    end
  end

  # test('calls both updateLambdaCode() and updateLambdaConfiguration() API when it receives both code and configuration change')
  #
  # One update_stack carries both, as CloudFormation applies both.
  def test_a_code_and_configuration_change_together_update_the_function
    described = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "current-bucket", "S3Key" => "current-key" },
      "FunctionName" => "my-function", "Description" => "Old Description" } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => described } }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Bucket" => "new-bucket", "S3Key" => "new-key" },
      "FunctionName" => "my-function", "Description" => "New Description" } }
    body = JSON.generate({ "Resources" => { "Func" => renamed } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_equal :deployed, result.outcome, mode
      template = fresh.kwargs_of(:update_stack).first[:template]
      assert_includes template, "new-key", mode
      assert_includes template, "New Description", mode
    end
  end

  # test('S3ObjectVersion is hotswappable')
  def test_s3_object_version_is_hotswappable
    versioned = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Key" => "current-key", "S3ObjectVersion" => "current-obj" },
      "FunctionName" => "my-function" } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => versioned } }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "S3Key" => "new-key", "S3ObjectVersion" => "new-obj" },
      "FunctionName" => "my-function" } }
    body = JSON.generate({ "Resources" => { "Func" => renamed } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_equal :deployed, result.outcome, mode
      assert_includes fresh.kwargs_of(:update_stack).first[:template], "new-obj", mode
    end
  end

  # test('calls the updateLambdaCode() API when it receives only a code difference in a Lambda function (Inline Node.js code)')
  #
  # The origin zips the inline code; CloudFormation takes ZipFile as written,
  # so the engine sends the template unchanged (section 21).
  def test_an_inline_node_code_change_updates_the_function
    inline = { "Type" => FUNCTION, "Properties" => { "Code" => { "ZipFile" => "exports.handler = () => {return true}" },
      "Runtime" => "nodejs24.x", "FunctionName" => "my-function" } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => inline } }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "ZipFile" => "exports.handler = () => {return false}" },
      "Runtime" => "nodejs24.x", "FunctionName" => "my-function" } }
    body = JSON.generate({ "Resources" => { "Func" => renamed } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_equal :deployed, result.outcome, mode
      assert_includes fresh.kwargs_of(:update_stack).first[:template], "return false", mode
    end
  end

  # test('calls the updateLambdaCode() API when it receives only a code difference in a Lambda function (Inline Python code)')
  def test_an_inline_python_code_change_updates_the_function
    inline = { "Type" => FUNCTION, "Properties" => { "Code" => { "ZipFile" => "def handler(event, context):\n  return True" },
      "Runtime" => "python3.9", "FunctionName" => "my-function" } }
    given_stack_template(client, JSON.generate({ "Resources" => { "Func" => inline } }))
    renamed = { "Type" => FUNCTION, "Properties" => { "Code" => { "ZipFile" => "def handler(event, context):\n  return False" },
      "Runtime" => "python3.9", "FunctionName" => "my-function" } }
    body = JSON.generate({ "Resources" => { "Func" => renamed } })

    deploy_in_each_mode(client, body) do |mode, result, _out, fresh|
      assert_equal :deployed, result.outcome, mode
      assert_includes fresh.kwargs_of(:update_stack).first[:template], "return False", mode
    end
  end

  private

  # The client of the scenario being built, before deploy_in_each_mode copies
  # its template per mode.
  def client
    @client ||= D::Fakes::CfnClient.new
  end
end
