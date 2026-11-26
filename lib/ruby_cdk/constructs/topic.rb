# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "grant"

module RubyCdk
  module SNS
    # An SNS topic: the port of the CDK's Topic (aws-sns/lib/topic.ts), read
    # at commit c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   RubyCdk::SNS::Topic.new(stack, "Events",
    #     topic_name: "events", display_name: "Domain events")
    #
    # fifo: true marks the topic FIFO and names it with the .fifo suffix, as
    # the CDK's naming rule does; content_based_deduplication needs a FIFO
    # topic, and is refused on a standard one, as in the CDK. A topic is not a
    # retained type (architecture section 7).
    #
    # The grants are the CDK's (aws-sns/lib/topic-base.ts and its tests, at the
    # pinned commit): publish is sns:Publish on the topic's ARN; subscribe is
    # sns:Subscribe, the API call alone, as the CDK grants it.
    #
    # Encryption: this tool takes no option and writes no property, as the CDK
    # at the pinned commit does (topic.ts writes KmsMasterKeyId only when a key
    # prop is given; there is no managed-SSE property on the resource): AWS
    # encrypts a new topic at rest with an SNS-managed key by default, so the
    # template says nothing. A customer-managed key needs KmsMasterKeyId,
    # which this tool does not yet take; architecture section 21 records the
    # row.
    class Topic < Construct
      # The CDK's publish action (topic-base.ts:250).
      PUBLISH_ACTION = "sns:Publish"

      # The CDK's subscribe action (topic-base.ts, grantSubscribe).
      SUBSCRIBE_ACTION = "sns:Subscribe"

      attr_reader :fifo

      def initialize(scope, id, topic_name: nil, display_name: nil, fifo: false, content_based_deduplication: false)
        super(scope, id)
        @fifo = fifo ? true : false
        @topic_name = topic_name.nil? || topic_name.is_a?(String) && !topic_name.empty? ? topic_name :
          raise(UsageError, "#{path}: topic_name must be a non-empty String, got #{topic_name.inspect}")
        if @topic_name && @fifo && !@topic_name.end_with?(".fifo")
          @topic_name = "#{@topic_name}.fifo"
        end
        if content_based_deduplication && !@fifo
          raise UsageError, "#{path}: content_based_deduplication needs a FIFO topic, as in the CDK " \
            "(its ContentBasedDeduplicationNotAllowedOnStandardTopic)"
        end

        @resource = resource("Resource", "AWS::SNS::Topic",
          TopicName: @topic_name,
          DisplayName: display_name,
          FifoTopic: @fifo || nil,
          ContentBasedDeduplication: content_based_deduplication ? true : nil)
      end

      # The logical ID of the AWS::SNS::Topic under this construct, so that the
      # topic can sit in another resource's depends_on:.
      def logical_id
        @resource.logical_id
      end

      # The topic's ARN: SNS's attribute is TopicArn, not Arn.
      def arn
        Fn.get_att(@resource, "TopicArn")
      end

      # The topic's name: the one given, or the Ref of the resource.
      def topic_name
        @topic_name || Fn.ref(@resource)
      end

      # Grants the publish action to the principal (topic-base.ts,
      # grantPublish).
      def grant_publish(principal)
        Constructs::Grant.add_to_principal(principal, [ PUBLISH_ACTION ], [ arn ])
      end

      # Grants the subscribe action (topic-base.ts, grantSubscribe).
      def grant_subscribe(principal)
        Constructs::Grant.add_to_principal(principal, [ SUBSCRIBE_ACTION ], [ arn ])
      end
    end
  end
end
