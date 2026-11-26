# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "grant"

module RubyCdk
  module SQS
    # An SQS queue: the port of the CDK's Queue (aws-sqs/lib/queue.ts), read
    # at commit c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   RubyCdk::SQS::Queue.new(stack, "Jobs",
    #     queue_name: "jobs", visibility_timeout: 60, retention: 3_600)
    #
    # fifo: true marks the queue FIFO - the queue name then has to end in
    # .fifo, as SQS requires, and the CDK's own naming rule appends the suffix
    # when it is missing. A queue is not a retained type (architecture
    # section 7): nothing is written where the CDK writes Delete on both
    # policies, because the queue is deleted all the same.
    #
    # The grants are the CDK's (aws-sqs/lib/queue-base.ts and its tests, at the
    # pinned commit): consume is ReceiveMessage, ChangeMessageVisibility,
    # GetQueueUrl, DeleteMessage and GetQueueAttributes; send is SendMessage,
    # GetQueueAttributes and GetQueueUrl; purge is PurgeQueue,
    # GetQueueAttributes and GetQueueUrl; and grant takes any actions given.
    # All on the queue's ARN, to the principal's own policy - the CDK's
    # QueuePolicy exists for principals that cannot carry a statement, which is
    # not a case here.
    #
    # Encryption: this tool takes no option and writes no property, exactly as
    # the CDK at the pinned commit does when props.encryption is unset
    # (_determineEncryptionProps, queue.ts:459-468 writes {}): AWS encrypts a
    # new queue at rest with an SQS-managed key by default, so the template
    # says nothing. A customer-managed key needs KmsMasterKeyId, which this
    # tool does not yet take; architecture section 21 records the row.
    class Queue < Construct
      # The CDK's consume actions, in its order (queue-base.ts, its grant test).
      CONSUME_ACTIONS = [
        "sqs:ReceiveMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueUrl",
        "sqs:DeleteMessage", "sqs:GetQueueAttributes"
      ].freeze

      # The CDK's send actions, in its order.
      SEND_ACTIONS = [ "sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl" ].freeze

      # The CDK's purge actions, in its order.
      PURGE_ACTIONS = [ "sqs:PurgeQueue", "sqs:GetQueueAttributes", "sqs:GetQueueUrl" ].freeze

      attr_reader :fifo

      def initialize(scope, id, queue_name: nil, fifo: false, visibility_timeout: nil, retention: nil)
        super(scope, id)
        @fifo = fifo ? true : false
        @queue_name = queue_name.nil? || queue_name.is_a?(String) && !queue_name.empty? ? queue_name :
          raise(UsageError, "#{path}: queue_name must be a non-empty String, got #{queue_name.inspect}")
        if @queue_name && @fifo && !@queue_name.end_with?(".fifo")
          @queue_name = "#{@queue_name}.fifo"
        end

        @resource = resource("Resource", "AWS::SQS::Queue",
          QueueName: @queue_name,
          FifoQueue: @fifo || nil,
          VisibilityTimeout: valid_seconds(visibility_timeout, "visibility_timeout"),
          MessageRetentionPeriod: valid_seconds(retention, "retention"))
      end

      # The logical ID of the AWS::SQS::Queue under this construct, so that the
      # queue can sit in another resource's depends_on:.
      def logical_id
        @resource.logical_id
      end

      # The queue's ARN.
      def arn
        Fn.get_att(@resource, "Arn")
      end

      # The queue's URL, the Ref of the resource, as the CDK's queueUrl.
      def queue_url
        Fn.ref(@resource)
      end

      # Grants the consume actions to the principal (queue-base.ts,
      # grantConsumeMessages).
      def grant_consume_messages(principal)
        Constructs::Grant.add_to_principal(principal, CONSUME_ACTIONS, [ arn ])
      end

      # Grants the send actions (queue-base.ts, grantSendMessages).
      def grant_send_messages(principal)
        Constructs::Grant.add_to_principal(principal, SEND_ACTIONS, [ arn ])
      end

      # Grants the purge actions (queue-base.ts, grantPurge).
      def grant_purge(principal)
        Constructs::Grant.add_to_principal(principal, PURGE_ACTIONS, [ arn ])
      end

      # Grants the actions given (queue-base.ts, grant).
      def grant(principal, *actions)
        Constructs::Grant.add_to_principal(principal, actions, [ arn ])
      end

      private

      # Seconds on the wire, as the CDK writes Duration.seconds there. An
      # intrinsic - Fn.ref of a parameter - passes through; only a plain value
      # is checked here.
      def valid_seconds(value, what)
        return nil if value.nil?
        return value if value.is_a?(Integer) && value.positive?
        return value if value.is_a?(Hash)

        raise UsageError, "#{path}: #{what} must be a positive number of seconds or an intrinsic, got #{value.inspect}"
      end
    end
  end
end
