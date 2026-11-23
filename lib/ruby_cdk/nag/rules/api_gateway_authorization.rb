# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # RC-APIGW-001. A method, or a v2 route, is compliant when its
      # AuthorizationType is something other than NONE. A method with no
      # AuthorizationType counts as NONE: that is what API Gateway applies.
      # An OPTIONS method whose every response is the CORS preflight response
      # (status 204 with an Access-Control-Allow-* header) is left alone: a
      # preflight is never authorized.
      #
      # Ported from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0),
      # src/rules/apigw/APIGWAuthorization.ts, AwsSolutions-APIG4 in
      # src/packs/aws-solutions.ts: "The API does not implement
      # authorization." It reads CfnMethod and CfnRoute, exempts an OPTIONS
      # method only when checkCORSMethodResponses holds, and is
      # non-compliant when the authorization type is undefined or NONE.
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: "NONE" is read in any case, as cfn-nag's W59,
      # ApiGatewayMethodAuthorizationTypeRule (stelligent/cfn_nag, commit
      # 8b5f03da74202ba323a145e9d037ddce6cab9dec, MIT) reads it. Where the
      # source reports an error for an intrinsic inside MethodResponses and
      # then still judges the method, an intrinsic there ends the exemption as
      # not evaluated and the method is judged. AWS::ApiGatewayV2::Route is
      # ported with the method, as the source has it; the wave card names only
      # the method.
      class ApiGatewayAuthorization < Rule
        id "RC-APIGW-001"
        description "API Gateway method and route have an authorization type other than NONE"
        severity :high
        applies_to "AWS::ApiGateway::Method", "AWS::ApiGatewayV2::Route"

        AUTHORIZATION_TYPE = "Properties.AuthorizationType"
        METHOD = "AWS::ApiGateway::Method"
        HTTP_METHOD = "Properties.HttpMethod"
        METHOD_RESPONSES = "Properties.MethodResponses"
        RESPONSE_STATUS = "StatusCode"
        RESPONSE_PARAMETERS = "ResponseParameters"
        CORS_HEADER = "method.response.header.Access-Control-Allow-"
        PREFLIGHT = "OPTIONS"
        PREFLIGHT_STATUS = "204"
        NONE = "NONE"

        def audit
          v = values
          return if cors_preflight?(v)

          check(AUTHORIZATION_TYPE) do
            written = v.string(AUTHORIZATION_TYPE)
            next unless written.nil? || written.casecmp(NONE).zero?

            violate(AUTHORIZATION_TYPE,
              written.nil? ? "has no AuthorizationType, which API Gateway reads as NONE: set it to AWS_IAM, COGNITO_USER_POOLS or CUSTOM" \
                            : "has AuthorizationType NONE: set it to AWS_IAM, COGNITO_USER_POOLS or CUSTOM")
          end
        end

        private

        # The source's checkCORSMethodResponses: every method response is a
        # 204 with an Access-Control-Allow-* response parameter set to true.
        # Undecided when one of them cannot be read: then it is no exemption.
        def cors_preflight?(v)
          return false unless type == METHOD

          preflight = check(METHOD_RESPONSES) do
            next false unless v.string(HTTP_METHOD) == PREFLIGHT

            responses = v.item_paths(METHOD_RESPONSES)
            next false if responses.empty?

            responses.all? do |response|
              v.string("#{response}.#{RESPONSE_STATUS}") == PREFLIGHT_STATUS && cors_header?(v.hash("#{response}.#{RESPONSE_PARAMETERS}"))
            end
          end
          preflight == true
        end

        def cors_header?(parameters)
          parameters.nil? ? false : parameters.any? { |name, value| name.start_with?(CORS_HEADER) && value == true }
        end
      end
    end
  end
end
