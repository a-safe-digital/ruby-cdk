# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "grant"
require_relative "role"
require_relative "log_group"

module RubyCdk
  module Lambda
    # A Lambda function: the port of the CDK's Function
    # (aws-lambda/lib/function.ts), read at commit
    # c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   code = stack.asset.zip(__dir__.to_s, exclude: ["stack.rb"])
    #   RubyCdk::Lambda::Function.new(stack, "Fn",
    #     code: code, handler: "app.handler")
    #
    # The runtime is a String, never an enum: the vendored model publishes no
    # Runtime list, and the identifier ages. The default is "ruby4.0", set on
    # 2026-11-26 from AWS's supported-runtimes page (deprecation 2029-03-31;
    # the previous default, ruby3.4, is deprecated a year earlier); when AWS
    # retires it, pass runtime: with the current one. The
    # function's role is the CDK's ServiceRole default (function.ts:1038):
    # trusted by lambda.amazonaws.com, carrying the
    # AWSLambdaBasicExecutionRole managed policy that gives the function its
    # CloudWatch Logs permissions - or pass role: with an IAM::Role built
    # before, and grants to that role land on it.
    #
    # Where this tool differs from the CDK (architecture section 7 wins; the
    # rows are listed in section 21):
    #
    #   - The function's log group is a real AWS::Logs::LogGroup of this stack,
    #     named /aws/lambda/<function name> when the function has a literal
    #     name, kept for 731 days by default (log_retention:, the LogGroup's
    #     own CDK default at the pinned commit), and declared before the
    #     function with DependsOn, as the CDK orders an explicit log group. The
    #     CDK creates no log group (CloudFormation makes one without retention
    #     on first invoke) and its logRetention prop is a custom resource; this
    #     tool has no custom resources.
    #   - The function resource depends on the role resource as well
    #     (function.ts, this.resource.node.addDependency(this.role)).
    #
    # grant_invoke is the CDK's grantInvoke (aws-lambda/lib/function-base.ts):
    # lambda:InvokeFunction on the function's ARN, applied to the principal's
    # own policy. The CDK instead adds a Lambda::Permission to the function's
    # resource policy; this tool grants to identities only, so the statement
    # lands on the caller's role - the same permission, from the other side.
    class Function < Construct
      # The runtime identifier the examples pin. Dated: 2026-11-26, from AWS's
      # supported-runtimes page. No enum, by design - pass runtime: to move.
      DEFAULT_RUNTIME = "ruby4.0"

      # The managed policy the CDK's default ServiceRole carries
      # (function.ts:1040, AWSLambdaBasicExecutionRole).
      BASIC_EXECUTION_POLICY_ARN = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

      # The CDK's invoke action (function-base.ts, addPermission's default).
      INVOKE_ACTION = "lambda:InvokeFunction"

      attr_reader :runtime, :role, :log_group

      def initialize(scope, id, code:, handler:, role: nil, runtime: DEFAULT_RUNTIME, function_name: nil,
        memory_size: nil, timeout: nil, environment: {}, description: nil, log_retention: nil, initial_policy: [])
        super(scope, id)
        @runtime = valid_runtime(runtime)
        @handler = valid_handler(handler)
        @code = valid_code(code)
        @function_name = valid_function_name(function_name)
        @role = role || IAM::Role.new(self, "ServiceRole",
          assumed_by: "lambda.amazonaws.com",
          managed_policy_arns: [ BASIC_EXECUTION_POLICY_ARN ])
        # The CDK's initialPolicy (function.ts:1082), statements on the
        # function's role.
        Array(initial_policy).each { |statement| @role.add_to_policy(statement) }

        # The function's log group: /aws/lambda/<function name> when that name
        # is a literal, else a group without a name (CloudFormation then names
        # it at creation, as it does the one it makes itself).
        log_group_name = @function_name.is_a?(String) ? "/aws/lambda/#{@function_name}" : nil
        @log_group = Logs::LogGroup.new(self, "LogGroup", log_group_name: log_group_name, retention_days: log_retention)

        @resource = resource("Resource", "AWS::Lambda::Function",
          FunctionName: @function_name,
          Description: description,
          Code: code_location,
          Handler: @handler,
          Runtime: @runtime,
          Role: @role.arn,
          MemorySize: memory_size,
          Timeout: timeout,
          Environment: environment.empty? ? nil : { "Variables" => environment },
          depends_on: [ @role, @log_group ])
      end

      # The logical ID of the AWS::Lambda::Function under this construct, so
      # that the function can sit in another resource's depends_on:.
      def logical_id
        @resource.logical_id
      end

      # The function's ARN.
      def arn
        Fn.get_att(@resource, "Arn")
      end

      # The function's name: the one given, or the Ref of the resource.
      def function_name
        @function_name || Fn.ref(@resource)
      end

      # Grants lambda:InvokeFunction on this function's ARN to the principal
      # (function-base.ts, grantInvoke): on the qualified ARN and on the
      # unqualified one, as the CDK grants both.
      def grant_invoke(principal)
        Constructs::Grant.add_to_principal(principal, [ INVOKE_ACTION ], [ qualified_arn, arn ])
      end

      private

      def valid_runtime(runtime)
        return runtime if runtime.is_a?(String) && !runtime.empty?

        raise UsageError, "#{path}: the runtime must be an identifier String such as \"#{DEFAULT_RUNTIME}\", got #{runtime.inspect}"
      end

      def valid_handler(handler)
        return handler if handler.is_a?(String) && !handler.empty?

        raise UsageError, "#{path}: the handler must be a String such as \"app.handler\", got #{handler.inspect}"
      end

      # The code is an asset of the stack, whose s3_location is the Code
      # property, or a Hash in CloudFormation's Code shape.
      def valid_code(code)
        return code if code.respond_to?(:s3_location)
        return code if code.is_a?(Hash) && !code.empty?

        raise UsageError, "#{path}: the code must be an asset of the stack (stack.asset.zip(...)) or a Hash in " \
          "CloudFormation's Code shape, got #{code.inspect}"
      end

      def valid_function_name(name)
        return nil if name.nil?
        return name if name.is_a?(String) && !name.empty?

        raise UsageError, "#{path}: the function name must be a non-empty String, got #{name.inspect}"
      end

      def code_location
        return @code.s3_location if @code.respond_to?(:s3_location)

        @code
      end

      # The qualified ARN the CDK's grant also names
      # (function-base.ts, resourceArnsForGrantInvoke and its test).
      def qualified_arn
        Fn.join("", [ arn, ":*" ])
      end
    end
  end
end
