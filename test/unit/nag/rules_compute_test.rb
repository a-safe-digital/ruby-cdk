# frozen_string_literal: true

require "test_helper"
require "support/nag_case"

# The compute rules: RC-LAMBDA-001, RC-LAMBDA-002, RC-APIGW-001.
class NagRulesComputeTest < Minitest::Test
  include NagCase

  FUNCTION = "AWS::Lambda::Function"
  METHOD = "AWS::ApiGateway::Method"
  ROUTE = "AWS::ApiGatewayV2::Route"

  def function(runtime: "ruby4.0", environment: nil, package_type: nil)
    properties = { "Runtime" => runtime, "Handler" => "index.handler", "Code" => { "ZipFile" => "x" } }
    properties["Environment"] = environment if environment
    properties["PackageType"] = package_type if package_type
    properties
  end

  # --- RC-LAMBDA-001: the runtime

  def test_lambda_runtime_passes_on_a_supported_runtime_of_each_family
    %w[ruby4.0 ruby3.4 nodejs22.x python3.13 python3.12 java21 java11.al2023].each do |runtime|
      report = check_resource(FUNCTION, function(runtime: runtime))

      assert_empty violations(report, "RC-LAMBDA-001"), runtime
    end
  end

  def test_lambda_runtime_passes_on_a_container_image_without_a_runtime
    image = check_resource(FUNCTION, function(runtime: nil, package_type: "Image"))
    image_with_a_runtime = check_resource(FUNCTION, function(package_type: "Image"))

    assert_findings(image, {})
    assert_findings(image_with_a_runtime, {})
  end

  def test_lambda_runtime_fails_on_a_runtime_lambda_has_retired
    retired = check_resource(FUNCTION, function(runtime: "nodejs6.10"))
    recently = check_resource(FUNCTION, function(runtime: "ruby3.2"))
    no_runtime = check_resource(FUNCTION, function(runtime: nil))
    dynamic_runtime = check_resource(FUNCTION, function(runtime: { "Ref" => "Runtime" }))
    unknown_family = check_resource(FUNCTION, function(runtime: "dotnet10"))
    dynamic_package_type = check_resource(FUNCTION, function(runtime: nil, package_type: { "Ref" => "Packaging" }))

    assert_one_violation(retired, "RC-LAMBDA-001", severity: :high, resource_type: FUNCTION, path: "Properties.Runtime",
      says: [ "nodejs6.10", "no longer supports", "nodejs24.x" ])
    assert_one_violation(recently, "RC-LAMBDA-001", severity: :high, resource_type: FUNCTION, path: "Properties.Runtime",
      says: [ "ruby3.2", "ruby4.0" ])
    assert_one_violation(no_runtime, "RC-LAMBDA-001", severity: :high, resource_type: FUNCTION, path: "Properties.Runtime",
      says: [ "no Runtime", "ruby4.0" ])

    assert_empty violations(dynamic_runtime, "RC-LAMBDA-001")
    assert_equal [ "Properties.Runtime" ], undecided(dynamic_runtime, "RC-LAMBDA-001")
    skipped = assert_undecided(unknown_family, "RC-LAMBDA-001", path: "Properties.Runtime")
    assert_includes skipped.reason, "does not cover"
    # With the packaging dynamic the rule cannot know whether a runtime is needed at all:
    # both reads are left undecided.
    assert_equal [ "Properties.PackageType", "Properties.Runtime" ].sort, undecided(dynamic_package_type, "RC-LAMBDA-001").sort
  end

  def test_lambda_runtime_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(FUNCTION, function(runtime: "ruby3.2"), **rules_to_suppress({ "Id" => "RC-LAMBDA-001", "Reason" => "The upgrade lands with the next release; tracked in the backlog." }))

    assert_suppressed(report, "RC-LAMBDA-001", reason: "The upgrade lands with the next release; tracked in the backlog.")
  end

  # --- RC-LAMBDA-002: a secret in the environment

  def test_lambda_environment_passes_when_no_variable_is_named_like_a_secret
    report = check_resource(FUNCTION, function(environment: { "Variables" => { "LOG_LEVEL" => "info", "TABLE" => { "Ref" => "Table" } } }))

    assert_findings(report, {})
  end

  def test_lambda_environment_passes_when_the_secret_comes_from_a_managed_secret
    secrets_manager = check_resource(FUNCTION, function(environment: { "Variables" => { "DB_PASSWORD" => "{{resolve:secretsmanager:prod/db:SecretString:password}}" } }))
    secure_parameter = check_resource(FUNCTION, function(environment: { "Variables" => { "DB_PASSWORD" => "{{resolve:ssm-secure:/prod/db/password}}" } }))

    assert_findings(secrets_manager, {})
    assert_findings(secure_parameter, {})
  end

  def test_lambda_environment_fails_on_a_literal_in_a_variable_named_like_a_secret
    password = check_resource(FUNCTION, function(environment: { "Variables" => { "DB_PASSWORD" => "hunter2" } }))
    every_word = check_resource(FUNCTION, function(environment: { "Variables" => {
      "API_KEY" => "k", "MY_SECRET" => "s", "PASSWORD" => "p", "AUTH_TOKEN" => "t", "AWS_CREDENTIAL" => "c", "SshKey" => "k"
    } }))
    # The name test is a substring test, on purpose: KEYBOARD_LAYOUT holds "KEY"
    # and is flagged; a variable with none of the words is not read at all.
    almost = check_resource(FUNCTION, function(environment: { "Variables" => { "KEYBOARD_LAYOUT" => "qwerty", "PLAN" => "free", "REGION_NAME" => { "Ref" => "Region" } } }))
    not_a_literal = check_resource(FUNCTION, function(environment: { "Variables" => { "DB_PASSWORD" => { "Ref" => "Password" } } }))
    not_resolved_yet = check_resource(FUNCTION, function(environment: { "Variables" => { "DB_PASSWORD" => { "Fn::If" => [ "Prod", "hunter2", "test" ] } } }))
    broken_reference = check_resource(FUNCTION, function(environment: { "Variables" => { "TOKEN" => "{{resolve:ssm-secure:/t}" } }))

    assert_one_violation(password, "RC-LAMBDA-002", severity: :high, resource_type: FUNCTION, path: "Properties.Environment.Variables.DB_PASSWORD",
      says: [ "named like a secret", "Secrets Manager" ])
    found = violations(every_word, "RC-LAMBDA-002")
    assert_equal 6, found.length
    assert_equal [ "Properties.Environment.Variables.API_KEY", "Properties.Environment.Variables.AUTH_TOKEN",
      "Properties.Environment.Variables.AWS_CREDENTIAL", "Properties.Environment.Variables.MY_SECRET",
      "Properties.Environment.Variables.PASSWORD", "Properties.Environment.Variables.SshKey" ], found.map(&:path).sort
    assert_findings(almost, { "RC-LAMBDA-002" => [ "Only" ] })
    assert_includes violations(almost, "RC-LAMBDA-002").first.path, "KEYBOARD_LAYOUT"
    assert_empty violations(not_a_literal, "RC-LAMBDA-002")
    assert_equal [ "Properties.Environment.Variables.DB_PASSWORD" ], undecided(not_a_literal, "RC-LAMBDA-002")
    assert_empty violations(not_resolved_yet, "RC-LAMBDA-002")
    assert_equal [ "Properties.Environment.Variables.DB_PASSWORD" ], undecided(not_resolved_yet, "RC-LAMBDA-002")
    # A dynamic reference that is not closed is not one: the value is written out.
    assert_one_violation(broken_reference, "RC-LAMBDA-002", severity: :high, resource_type: FUNCTION, path: "Properties.Environment.Variables.TOKEN", says: [ "written in the template" ])
  end

  def test_lambda_environment_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(FUNCTION, function(environment: { "Variables" => { "DB_PASSWORD" => "hunter2" } }),
      **rules_to_suppress({ "Id" => "RC-LAMBDA-002", "Reason" => "A sandbox only; the real function takes it from Secrets Manager." }))

    assert_suppressed(report, "RC-LAMBDA-002", reason: "A sandbox only; the real function takes it from Secrets Manager.")
  end

  def test_lambda_environment_counts_a_dynamic_variables_map
    report = check_resource(FUNCTION, function(environment: { "Variables" => { "Ref" => "Variables" } }))

    assert_undecided(report, "RC-LAMBDA-002", path: "Properties.Environment.Variables")
  end

  # --- RC-APIGW-001: the authorization type

  def test_api_gateway_passes_on_an_authorized_method
    aws_iam = check_resource(METHOD, { "HttpMethod" => "GET", "AuthorizationType" => "AWS_IAM" })
    cognito = check_resource(METHOD, { "HttpMethod" => "GET", "AuthorizationType" => "COGNITO_USER_POOLS" })
    custom = check_resource(METHOD, { "HttpMethod" => "GET", "AuthorizationType" => "CUSTOM", "AuthorizerId" => { "Ref" => "Authorizer" } })
    route = check_resource(ROUTE, { "AuthorizationType" => "AWS_IAM" })

    assert_findings(aws_iam, {})
    assert_findings(cognito, {})
    assert_findings(custom, {})
    assert_findings(route, {})
  end

  def test_api_gateway_fails_on_none_in_any_case_and_on_an_absent_authorization_type
    upper = check_resource(METHOD, { "HttpMethod" => "GET", "AuthorizationType" => "NONE" })
    mixed = check_resource(METHOD, { "HttpMethod" => "GET", "AuthorizationType" => "None" })
    lower = check_resource(METHOD, { "HttpMethod" => "GET", "AuthorizationType" => "none" })
    absent = check_resource(METHOD, { "HttpMethod" => "GET" })
    route = check_resource(ROUTE, { "AuthorizationType" => "NONE" })

    assert_one_violation(upper, "RC-APIGW-001", severity: :high, resource_type: METHOD, path: "Properties.AuthorizationType",
      says: [ "NONE", "AWS_IAM, COGNITO_USER_POOLS or CUSTOM" ])
    assert_one_violation(mixed, "RC-APIGW-001", severity: :high, resource_type: METHOD, path: "Properties.AuthorizationType", says: [ "NONE" ])
    assert_one_violation(lower, "RC-APIGW-001", severity: :high, resource_type: METHOD, path: "Properties.AuthorizationType", says: [ "NONE" ])
    assert_one_violation(absent, "RC-APIGW-001", severity: :high, resource_type: METHOD, path: "Properties.AuthorizationType",
      says: [ "no AuthorizationType", "reads as NONE" ])
    assert_one_violation(route, "RC-APIGW-001", severity: :high, resource_type: ROUTE, path: "Properties.AuthorizationType", says: [ "NONE" ])
  end

  def test_api_gateway_passes_a_cors_preflight_without_reading_its_authorization_type
    preflight = check_resource(METHOD, { "HttpMethod" => "OPTIONS", "AuthorizationType" => "NONE", "MethodResponses" => [
      { "StatusCode" => "204", "ResponseParameters" => { "method.response.header.Access-Control-Allow-Origin" => true, "method.response.header.Access-Control-Allow-Methods" => true } },
      { "StatusCode" => "204", "ResponseParameters" => { "method.response.header.Access-Control-Allow-Headers" => true } }
    ] })
    plain_options = check_resource(METHOD, { "HttpMethod" => "OPTIONS", "AuthorizationType" => "NONE" })
    not_all_preflight = check_resource(METHOD, { "HttpMethod" => "OPTIONS", "AuthorizationType" => "NONE", "MethodResponses" => [
      { "StatusCode" => "200", "ResponseParameters" => { "method.response.header.Access-Control-Allow-Origin" => true } }
    ] })

    assert_findings(preflight, {})
    assert_one_violation(plain_options, "RC-APIGW-001", severity: :high, resource_type: METHOD, path: "Properties.AuthorizationType", says: [ "NONE" ])
    assert_one_violation(not_all_preflight, "RC-APIGW-001", severity: :high, resource_type: METHOD, path: "Properties.AuthorizationType", says: [ "NONE" ])
  end

  def test_api_gateway_counts_a_dynamic_authorization_type_or_method
    dynamic_type = check_resource(METHOD, { "HttpMethod" => "GET", "AuthorizationType" => { "Ref" => "AuthType" } })
    dynamic_method = check_resource(METHOD, { "HttpMethod" => { "Ref" => "Verb" }, "AuthorizationType" => "NONE" })
    dynamic_responses = check_resource(METHOD, { "HttpMethod" => "OPTIONS", "AuthorizationType" => "NONE", "MethodResponses" => { "Ref" => "Responses" } })

    assert_undecided(dynamic_type, "RC-APIGW-001", path: "Properties.AuthorizationType")
    # A literal NONE is a finding whatever the verb is and whatever the responses
    # hold: only the CORS exemption needs those, and failing to earn it cannot
    # hide a written NONE.
    assert_one_violation(dynamic_method, "RC-APIGW-001", severity: :high, resource_type: METHOD, path: "Properties.AuthorizationType", says: [ "NONE" ])
    assert_one_violation(dynamic_responses, "RC-APIGW-001", severity: :high, resource_type: METHOD, path: "Properties.AuthorizationType", says: [ "NONE" ])
  end

  def test_api_gateway_is_suppressed_when_the_resource_says_so_with_a_reason
    report = check_resource(METHOD, { "HttpMethod" => "GET", "AuthorizationType" => "NONE" }, **rules_to_suppress({ "Id" => "RC-APIGW-001", "Reason" => "A health check endpoint; nothing behind it." }))

    assert_suppressed(report, "RC-APIGW-001", reason: "A health check endpoint; nothing behind it.")
  end
end
