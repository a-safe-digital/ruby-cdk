# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "grant"

module RubyCdk
  module Logs
    # A CloudWatch Logs log group: the port of the CDK's LogGroup
    # (aws-logs/lib/log-group.ts), read at commit
    # c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   RubyCdk::Logs::LogGroup.new(stack, "Logs",
    #     log_group_name: "/aws/lambda/my-function", retention_days: 30)
    #
    # Retention defaults to 731 days, the CDK's own default at the pinned
    # commit (log-group.ts: `retentionInDays = RetentionDays.TWO_YEARS`), so a
    # log group out of this tool never keeps logs forever. retention_days:
    # :infinite writes no RetentionInDays, as the CDK's RetentionDays.INFINITE
    # does not, and a retention of 0 or less is refused, as the CDK's
    # RetentionDaysPositive refuses one. The group is a retained type
    # (architecture section 7), which the synthesis gives every
    # AWS::Logs::LogGroup.
    #
    # The grants are the CDK's (aws-logs/lib/log-group-grants.ts, at the same
    # commit): grant_write is logs:CreateLogStream and logs:PutLogEvents on the
    # group's ARN; grant_read adds the read actions on both the group's bare
    # ARN and the GetAtt Arn that carries the stream wildcard, as the CDK's
    # grants.read does. grant_read_write does the two together, which the CDK's
    # grants.actions does with the actions given.
    class LogGroup < Construct
      # The CDK's default retention (log-group.ts, RetentionDays.TWO_YEARS).
      DEFAULT_RETENTION_DAYS = 731

      # The CDK's write actions (log-group-grants.ts, write).
      WRITE_ACTIONS = [ "logs:CreateLogStream", "logs:PutLogEvents" ].freeze

      # The CDK's read actions (log-group-grants.ts, read).
      READ_ACTIONS = [
        "logs:FilterLogEvents", "logs:GetLogEvents", "logs:GetLogGroupFields",
        "logs:DescribeLogGroups", "logs:DescribeLogStreams"
      ].freeze

      attr_reader :retention_days

      def initialize(scope, id, log_group_name: nil, retention_days: nil)
        super(scope, id)
        @log_group_name = valid_name(log_group_name)
        @retention_days = valid_retention(retention_days)

        @resource = resource("Resource", "AWS::Logs::LogGroup",
          LogGroupName: @log_group_name,
          RetentionInDays: @retention_days == :infinite ? nil : (@retention_days || DEFAULT_RETENTION_DAYS))
      end

      # The log group's name: the one given, or the Ref of the resource.
      def log_group_name
        @log_group_name || Fn.ref(@resource)
      end

      # The logical ID of the AWS::Logs::LogGroup under this construct, so that
      # the group can sit in another resource's depends_on:.
      def logical_id
        @resource.logical_id
      end

      # The log group's ARN, with the stream wildcard behind it (the GetAtt Arn
      # attribute reads `...:log-group:<name>:*`).
      def arn
        Fn.get_att(@resource, "Arn")
      end

      # The log group's bare ARN, without the wildcard: the CDK's
      # CfnLogGroup.arnForLogGroup. Built with Fn.sub over CloudFormation's own
      # pseudo parameters, so it works in a stack with no concrete env.
      def group_arn
        Fn.sub("arn:${AWS::Partition}:logs:${AWS::Region}:${AWS::AccountId}:log-group:${Group}",
          "Group" => Fn.ref(@resource))
      end

      # Grants the write actions to the principal (log-group-grants.ts, write).
      def grant_write(principal)
        Constructs::Grant.add_to_principal(principal, WRITE_ACTIONS, [ arn ])
      end

      # Grants the read actions on the bare ARN and on the GetAtt Arn
      # (log-group-grants.ts, read).
      def grant_read(principal)
        Constructs::Grant.add_to_principal(principal, READ_ACTIONS, [ group_arn, arn ])
      end

      # Grants both (log-group-grants.ts, actions with the two lists given).
      def grant_read_write(principal)
        Constructs::Grant.add_to_principal(principal, READ_ACTIONS + WRITE_ACTIONS, [ group_arn, arn ])
      end

      private

      def valid_name(name)
        return nil if name.nil?
        return name if name.is_a?(String) && !name.empty?

        raise UsageError, "#{path}: the log group name must be a non-empty String, got #{name.inspect}"
      end

      def valid_retention(days)
        return DEFAULT_RETENTION_DAYS if days.nil?
        return days if days == :infinite
        return days if days.is_a?(Integer) && days.positive?

        raise UsageError, "#{path}: retention_days must be a positive number of days or :infinite, got #{days.inspect}"
      end
    end
  end
end
