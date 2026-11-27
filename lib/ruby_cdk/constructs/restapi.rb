# frozen_string_literal: true

require "digest"
require "json"
require_relative "../errors"
require_relative "../fn"
require_relative "grant"

module RubyCdk
  module ApiGateway
    # A REST API with a Lambda proxy: the port of the CDK's LambdaRestApi over
    # the RestApi it extends (aws-apigateway/lib/lambda-api.ts,
    # integrations/lambda.ts and restapi.ts), read at commit
    # c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   api = RubyCdk::ApiGateway::RestApi.new(stack, "Api",
    #     handler: function, rest_api_name: "notes-api")
    #
    # One construct builds the five resources the CDK's own minimal template
    # shows (its restapi.test.ts, "minimal setup"): the AWS::ApiGateway::RestApi
    # named after the construct's id when rest_api_name is left out
    # (restapi.ts:436), the {proxy+} resource under the root
    # (resource.ts:199-201), the ANY method on the proxy and on the root - a
    # proxy under the root puts its method on both (resource.ts:630-640) - the
    # AWS::ApiGateway::Deployment (restapi.ts:737-752, "Automatically created
    # by the RestApi construct") and the prod AWS::ApiGateway::Stage, plus the
    # Endpoint output (restapi.ts:753, urlForPath).
    #
    # The integration is the CDK's Lambda proxy: AWS_PROXY, POST, the
    # invoke URI of the function (integrations/lambda.ts:47-59). Authorization
    # is NONE, the CDK's default (method.ts:255), and authorization: takes the
    # other three values the CDK's AuthorizationType has. Note the nag rule
    # RC-APIGW-001: a method with AuthorizationType NONE fails it when the
    # template is synthesized into cdk.out; pass authorization: :aws_iam and
    # grant invoke to the caller's role to clear it.
    #
    # Where this tool differs from the CDK (architecture section 7 wins; the
    # rows are listed in section 21):
    #
    #   - No Lambda::Permission. The CDK's LambdaIntegration.bind gives
    #     apigateway.amazonaws.com permission to invoke the function
    #     (integrations/lambda.ts:61-80); this tool grants to identities only
    #     and has no resource policies, so the function's own policy is not
    #     broadened here - function.grant_invoke is the identity-side wiring.
    #   - No CloudWatch role and no AWS::ApiGateway::Account
    #     (restapi.ts:689-714): the account-wide effect of a role per API is
    #     not a safe default to write silently; logs go to the function's own
    #     role here.
    #   - The Deployment's logical id carries a short hash of the API's
    #     method set, as the CDK's one hashed logical id does
    #     (deployment.ts:63-77, 184-202): without it, a changed API would
    #     never reach a new deployment and the stage would keep serving the
    #     old one. D-004's rule - ids the user writes, never a hash - keeps
    #     every other id; this hash is over the method set, not over construct
    #     paths, so moving code replaces nothing and changing the API
    #     replaces only the deployment, which is the CDK's own semantics.
    class RestApi < Construct
      # The CDK's AuthorizationType values (method.ts, AuthorizationType).
      AUTHORIZATION_TYPES = %w[NONE AWS_IAM COGNITO_USER_POOLS CUSTOM].freeze

      # The CDK's stage name default (restapi.ts:744).
      DEFAULT_STAGE_NAME = "prod"

      # The CDK's deployment description (restapi.ts:740).
      DEPLOYMENT_DESCRIPTION = "Automatically created by the RestApi construct"

      # The invoke path of the Lambda proxy integration
      # (integrations/lambda.ts:53-58).
      INVOKE_PATH = "arn:${AWS::Partition}:apigateway:${AWS::Region}:lambda:path/" \
        "2015-03-31/functions/${FunctionArn}/invocations"

      attr_reader :rest_api_name, :stage_name, :authorization

      def initialize(scope, id, handler:, rest_api_name: nil, description: nil,
        stage_name: DEFAULT_STAGE_NAME, authorization: "NONE")
        super(scope, id)
        @handler = valid_handler(handler)
        @rest_api_name = rest_api_name.nil? ? id : valid_name(rest_api_name)
        @stage_name = valid_stage_name(stage_name)
        @authorization = valid_authorization(authorization)

        api_properties = { "Name" => @rest_api_name, "Description" => description }
        @api_resource = resource("Resource", "AWS::ApiGateway::RestApi", properties: api_properties)

        @proxy_resource = resource("Proxy", "AWS::ApiGateway::Resource",
          ParentId: Fn.get_att(@api_resource, "RootResourceId"),
          PathPart: "{proxy+}",
          RestApiId: Fn.ref(@api_resource))

        method_properties = [
          method_properties(Fn.get_att(@api_resource, "RootResourceId")),
          method_properties(Fn.ref(@proxy_resource))
        ]
        @method_resources = method_properties.each_with_index.map do |properties, index|
          resource(index.zero? ? "RootMethod" : "ProxyMethod", "AWS::ApiGateway::Method", properties: properties)
        end

        # The Deployment is the CDK's one hashed logical id: a short hash of
        # the API's method set follows the ids in front of it, so a changed
        # API gets a new deployment (deployment.ts:63-77, 184-202).
        @deployment_resource = resource("Deployment#{hash_of(api_properties, method_properties)}",
          "AWS::ApiGateway::Deployment",
          RestApiId: Fn.ref(@api_resource),
          Description: DEPLOYMENT_DESCRIPTION,
          depends_on: @method_resources)

        @stage_resource = resource("Stage", "AWS::ApiGateway::Stage",
          StageName: @stage_name,
          RestApiId: Fn.ref(@api_resource),
          DeploymentId: Fn.ref(@deployment_resource))

        # The Endpoint output, named after the API (restapi.ts:753): the id's
        # letters and digits, so that a hyphenated id stays a legal output
        # name. Two APIs whose stripped ids agree collide loudly here, at the
        # duplicate's declaration.
        stack.output("#{id.gsub(/[^A-Za-z0-9]/, "")}Endpoint", value: url)
      end

      # The logical ID of the AWS::ApiGateway::RestApi under this construct,
      # so that the API can sit in another resource's depends_on:.
      def logical_id
        @api_resource.logical_id
      end

      # The API's id: the Ref of the RestApi resource, as the CDK's restApiId
      # is the resource's ref (restapi.ts:1024).
      def rest_api_id
        Fn.ref(@api_resource)
      end

      # The invoke URL of the prod stage, as the CDK's url and its Endpoint
      # output write it (restapi.ts, urlForPath).
      def url
        Fn.join("", [
          "https://",
          Fn.ref(@api_resource),
          ".execute-api.",
          Fn.ref("AWS::Region"),
          ".",
          Fn.ref("AWS::URLSuffix"),
          "/",
          Fn.ref(@stage_resource),
          "/"
        ])
      end

      private

      def valid_handler(handler)
        return handler if handler.respond_to?(:arn)

        raise UsageError, "#{path}: handler takes a function with an arn, got #{handler.inspect}"
      end

      def valid_name(name)
        return name if name.is_a?(String) && !name.empty?

        raise UsageError, "#{path}: rest_api_name must be a non-empty String, got #{name.inspect}"
      end

      def valid_stage_name(name)
        return name if name.is_a?(String) && !name.empty?

        raise UsageError, "#{path}: stage_name must be a non-empty String, got #{name.inspect}"
      end

      def valid_authorization(authorization)
        value = authorization.is_a?(Symbol) ? authorization.name.upcase : authorization
        return value if AUTHORIZATION_TYPES.include?(value)

        raise UsageError, "#{path}: authorization takes #{AUTHORIZATION_TYPES.map(&:inspect).join(", ")}, " \
          "got #{authorization.inspect}"
      end

      # The ANY method on one resource: HttpMethod, ResourceId, RestApiId,
      # AuthorizationType and the Lambda proxy integration, the properties the
      # CDK's method writes (method.ts:246-267) for this shape.
      def method_properties(resource_id)
        {
          "HttpMethod" => "ANY",
          "ResourceId" => resource_id,
          "RestApiId" => Fn.ref(@api_resource),
          "AuthorizationType" => @authorization,
          "Integration" => {
            "Type" => "AWS_PROXY",
            "IntegrationHttpMethod" => "POST",
            "Uri" => Fn.sub(INVOKE_PATH, "FunctionArn" => @handler.arn)
          }
        }
      end

      # Eight hex characters of SHA-256 over the canonical JSON of the data,
      # the shape unique_name uses for its suffix. The method set and the
      # API's own properties are the CDK's hashComponents
      # (deployment.ts:184-202).
      def hash_of(*data)
        Digest::SHA256.hexdigest(data.map { |item| JSON.generate(canonical(item)) }.join)[0, 8]
      end

      # Keys sorted and stringified, recursively: two Hashes that say the same
      # thing hash the same whatever order they were written in.
      def canonical(value)
        case value
        when Hash then value.to_h { |key, item| [ key.to_s, canonical(item) ] }.sort.to_h
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end
    end
  end
end
