# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/constructs"
require "ruby_cdk/test"
require "support/core_helpers"

# This tool's own tests of the Secrets Manager reference, what no CDK case
# reaches here (docs/07-testing.md section 10): the reference is not a
# construct, so the tests are on the strings and the hash it answers, against
# the CDK's own expectations quoted from its tests (aws-secretsmanager/test/
# secret.test.ts, "import by secret name v2" and the dynamicReferenceKey
# cases, at the pinned commit).
class ConstructsSecretTest < CoreHelpers::TestCase
  def test_the_arn_is_the_partial_arn_of_from_secret_name_v2
    secret = RubyCdk::SecretsManager::Secret.from_name("MySecret")

    assert_equal "MySecret", secret.name
    # The CDK's test resolves `arn:${partition}:secretsmanager:${region}:
    # ${account}:secret:MySecret`; the same five parts, as one Fn::Sub here.
    assert_equal(
      { "Fn::Sub" => [
        "arn:${AWS::Partition}:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:${SecretName}",
        { "SecretName" => "MySecret" }
      ] },
      secret.arn
    )
    assert_equal secret.arn, RubyCdk::SecretsManager::Secret.arn_from_name("MySecret")
  end

  def test_the_secret_value_is_the_resolve_reference_against_the_arn
    # The CDK's "import by secret name v2" resolves
    # {{resolve:secretsmanager:arn:...:secret:MySecret:SecretString:::}}; the
    # same string, as an Fn::Sub over the pseudo parameters.
    assert_equal(
      { "Fn::Sub" =>
        "{{resolve:secretsmanager:arn:${AWS::Partition}:secretsmanager:${AWS::Region}:${AWS::AccountId}:" \
        "secret:MySecret:SecretString:::}}" },
      RubyCdk::SecretsManager::Secret.secret_value_from_name("MySecret")
    )
  end

  def test_the_json_field_and_the_version_go_into_the_resolve_string
    # The CDK's dynamicReferenceKey cases: arn:...:SecretString:json-key:
    # version-stage: and arn:...:SecretString:json-key::version-id.
    [
      [ { json_field: "password" }, "SecretString:password::" ],
      [ { json_field: "json-key", version_stage: "version-stage" }, "SecretString:json-key:version-stage:" ],
      [ { json_field: "json-key", version_id: "version-id" }, "SecretString:json-key::version-id" ]
    ].each do |options, tail|
      value = RubyCdk::SecretsManager::Secret.secret_value_from_name("MySecret", **options)
      assert_match(/secret:MySecret:#{Regexp.escape(tail)}\}\}/, value["Fn::Sub"])
    end
  end

  def test_a_stage_and_an_id_cannot_go_together
    error = assert_raises(RubyCdk::UsageError) do
      RubyCdk::SecretsManager::Secret.secret_value_from_name("MySecret",
        version_stage: "a-stage", version_id: "an-id")
    end

    assert_match(/were both provided but only one is allowed/, error.message)
  end

  def test_an_empty_name_and_a_name_with_a_colon_are_refused
    assert_raises(RubyCdk::UsageError) do
      RubyCdk::SecretsManager::Secret.from_name("")
    end
    error = assert_raises(RubyCdk::UsageError) do
      RubyCdk::SecretsManager::Secret.from_name("wrong:id")
    end

    assert_match(/is not an ARN but contains ":"/, error.message)
  end

  def test_the_reference_builds_nothing_and_grants_nothing
    app = build_app(env: TEST_ENV)
    stack = RubyCdk::Stack.new(app, "stack") do
      RubyCdk::SecretsManager::Secret.from_name("MySecret")
    end

    template = RubyCdk::Test.template(stack)
    template.resource_count_is("AWS::SecretsManager::Secret", 0)
    template.resource_count_is("AWS::IAM::Policy", 0)
  end

  def test_the_reference_works_inside_a_function_environment
    built, = build_stack do
      function = RubyCdk::Lambda::Function.new(self, "Fn",
        code: { "ZipFile" => "x" },
        handler: "app.handler",
        environment: { "DB_PASSWORD" => RubyCdk::SecretsManager::Secret.secret_value_from_name("prod/db") })
      function
    end

    RubyCdk::Test.template(built).has_resource_properties("AWS::Lambda::Function", {
      "Environment" => { "Variables" => {
        "DB_PASSWORD" => {
          "Fn::Sub" => "{{resolve:secretsmanager:arn:${AWS::Partition}:secretsmanager:${AWS::Region}:" \
            "${AWS::AccountId}:secret:prod/db:SecretString:::}}"
        }
      } }
    })
  end

  private

  # One stack in an App with the test env, whose build is the block. Answers
  # [stack, the block's value].
  def build_stack(&body)
    app = build_app(env: TEST_ENV)
    value = nil
    built = RubyCdk::Stack.new(app, "Stack") do
      value = instance_eval(&body)
    end
    [ built, value ]
  end

  def template(stack)
    RubyCdk::Test.template(stack)
  end
end
