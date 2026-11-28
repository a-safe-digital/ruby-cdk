# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "../lazy"
require_relative "grant"
require_relative "schedule"

module RubyCdk
  module Events
    # An EventBridge rule: the port of the CDK's Rule (aws-events/lib/rule.ts),
    # read at commit c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   rule = RubyCdk::Events::Rule.new(stack, "Schedule",
    #     schedule: RubyCdk::Events::Schedule.rate(10, :minutes))
    #   rule.add_event_pattern(source: [ "aws.ec2" ], detail_type: [ "EC2 Instance State-change Notification" ])
    #   rule.add_target(function)
    #
    # A schedule or an event pattern must be there - the CDK fails synthesis
    # without either (rule.ts:354-356) - and here the check runs at resolve:
    # a rule may be built bare and given its pattern after, and one without
    # either fails the synthesis with the same words, from the Lazy that
    # stands in for the EventPattern. A rule name, when given, is the CDK's
    # physical name: 1 to 64 characters, letters, digits, periods, hyphens
    # and underscores (rule.ts:345-352), checked at construction. schedule:
    # takes a RubyCdk::Events::Schedule or the expression String.
    #
    # The event pattern is the CDK's EventPattern hash, written as given -
    # the property is a verbatim zone, so the keys stay as CloudFormation
    # reads them - with detail_type renamed "detail-type", as the CDK's
    # renderEventPattern does (aws-events/lib/util.ts:59-76). add_event_pattern
    # merges into the rule's pattern, as the CDK's does (util.ts:14-56):
    # arrays are concatenated and de-duplicated in order, nested objects
    # recurse, and a bare value is refused, as the CDK refuses one.
    #
    # Where this tool differs from the CDK (architecture section 7 wins; the
    # row is in section 21): add_target records the target on the rule and
    # writes the permission the delivery needs on the function's resource
    # policy, as the CDK's Lambda target does - principal events.amazonaws.com,
    # SourceArn the rule's ARN, one AWS::Lambda::Permission per rule and
    # function (aws-events-targets/lib/lambda.ts:34, util.ts:90-108). The
    # identity-based side is a separate grant: call function.grant_invoke on a
    # role of your own when a role - not the events service - is to invoke.
    class Rule < Construct
      # The CDK's own limit (rule.ts:358-360).
      MAX_TARGETS = 5

      # The CDK's enabled default (rule.ts:165): a rule without the prop is
      # enabled, and the State is written either way.
      DEFAULT_ENABLED = true

      attr_reader :schedule

      def initialize(scope, id, rule_name: nil, description: nil, enabled: DEFAULT_ENABLED,
        schedule: nil, event_pattern: nil, event_bus_name: nil, targets: [])
        super(scope, id)
        @rule_name = valid_name(rule_name)
        if event_bus_name && schedule
          raise UsageError, "#{path}: Cannot associate rule with 'eventBus' when using 'schedule'"
        end
        @schedule_expression = schedule_expression(schedule)
        @event_bus_name = valid_bus(event_bus_name)
        @targets = []
        @granted = []
        @pattern = {}

        # The pattern and the targets stand behind Lazies, so that a pattern
        # or a target added after the rule was built is on it, and a rule
        # with neither a pattern nor a schedule fails the synthesis with the
        # CDK's words (rule.ts:354-356).
        @resource = resource("Resource", "AWS::Events::Rule",
          Name: @rule_name,
          Description: description,
          State: enabled == false ? "DISABLED" : "ENABLED",
          ScheduleExpression: @schedule_expression,
          EventPattern: Lazy.new { rendered_pattern },
          Targets: Lazy.new { @targets.empty? ? nil : @targets },
          EventBusName: @event_bus_name)

        add_event_pattern(event_pattern)
        Array(targets).each { |target| add_target(target) }
      end

      # The logical ID of the AWS::Events::Rule under this construct, so that
      # the rule can sit in another resource's depends_on:.
      def logical_id
        @resource.logical_id
      end

      # The rule's ARN.
      def arn
        Fn.get_att(@resource, "Arn")
      end

      # The rule's name: the one given, or the Ref of the resource.
      def rule_name
        @rule_name || Fn.ref(@resource)
      end

      # Adds an event pattern filter, merged into the rule's own: the CDK's
      # addEventPattern (rule.ts:335-339) with its mergeEventPattern
      # (util.ts:14-56). Arrays are concatenated and de-duplicated in order,
      # objects recurse, and a bare value is refused, as the CDK refuses one.
      def add_event_pattern(pattern)
        return if pattern.nil?
        unless pattern.is_a?(Hash)
          raise UsageError, "#{path}: Invalid event pattern '#{pattern.inspect}', expecting an object or an array"
        end

        merge_pattern(@pattern, stringify_keys(pattern))
        nil
      end

      # Adds a Lambda function as a target (aws-events-targets/lib/lambda.ts,
      # bind): the Targets entry, Id Target0 and on, Arn the function's, plus
      # the permission the delivery needs on the function's resource policy
      # (util.ts:90-108) - principal events.amazonaws.com, SourceArn this
      # rule's ARN, written once per function however many targets carry it,
      # as the CDK writes it once (its tryFindChild guard). The permission's
      # id names the rule, where the CDK's names the handler, because the
      # resource sits under the function here (D-029).
      def add_target(function)
        unless function.respond_to?(:arn)
          raise UsageError, "#{path}: add_target takes a function with an arn, got #{function.inspect}"
        end
        if @targets.length >= MAX_TARGETS
          raise UsageError, "#{path}: Event rule cannot have more than #{MAX_TARGETS} targets."
        end

        @targets << { "Id" => "Target#{@targets.length}", "Arn" => function.arn }
        unless @granted.include?(function)
          function.add_permission("AllowEventRule#{logical_id}", principal: "events.amazonaws.com",
            source_arn: arn)
          @granted << function
        end
        nil
      end

      # The targets added so far, in order.
      def targets
        @targets.dup.freeze
      end

      private

      # schedule: takes a Schedule or its expression String.
      def schedule_expression(schedule)
        return nil if schedule.nil?
        return schedule.expression_string if schedule.is_a?(Schedule)
        return schedule if schedule.is_a?(String) && !schedule.empty?

        raise UsageError, "#{path}: schedule takes a RubyCdk::Events::Schedule or its expression String, " \
          "got #{schedule.inspect}"
      end

      def valid_bus(event_bus_name)
        return nil if event_bus_name.nil?
        return event_bus_name if event_bus_name.is_a?(String) && !event_bus_name.empty?

        raise UsageError, "#{path}: event_bus_name must be a non-empty String, got #{event_bus_name.inspect}"
      end

      # The CDK's validateRule name checks (rule.ts:345-352).
      def valid_name(name)
        return nil if name.nil?
        raise UsageError, "#{path}: the rule name must be a String, got #{name.inspect}" unless name.is_a?(String)
        if name.empty? || name.length > 64
          raise UsageError, "#{path}: Event rule name must be between 1 and 64 characters. Received: #{name}"
        end
        # The CDK's /^[\.\-_A-Za-z0-9]+$/, written with the strict anchors:
        # JavaScript's $ is the end of the string, and Ruby's $ would let a
        # trailing line break through.
        unless name.match?(/\A[.\-_A-Za-z0-9]+\z/)
          raise UsageError, "#{path}: Event rule name #{name} can contain only letters, numbers, periods, " \
            "hyphens, or underscores with no spaces."
        end

        name
      end

      # What the Lazy answers. The key is left out when the pattern is empty
      # and the schedule carries the rule; neither is the CDK's synthesis
      # failure, raised as this tool raises from a Lazy (the resolver makes
      # it an issue at this place in the template).
      def rendered_pattern
        if @pattern.empty?
          return nil if @schedule_expression

          raise Error, "#{path}: Either 'eventPattern' or 'schedule' must be defined"
        end

        render_pattern
      end

      # The CDK's renderEventPattern (util.ts:59-76): detail_type becomes
      # "detail-type"; every other key is written as given.
      def render_pattern
        @pattern.to_h do |key, value|
          [ key == "detail_type" ? "detail-type" : key, value ]
        end
      end

      # The CDK's mergeObject (util.ts:14-56): arrays are concatenated and
      # de-duplicated by their JSON identity, order kept; objects recurse;
      # a bare value is the CDK's EventPatternFieldsMustBeArrays. A nil field
      # is skipped, as the CDK skips an undefined one (util.ts:31-32).
      def merge_pattern(dest, src)
        src.each do |field, value|
          next if value.nil?

          unless value.is_a?(Hash) || value.is_a?(Array)
            raise UsageError, "#{path}: Invalid event pattern field { #{field}: #{JSON.generate(value)} }. " \
              "All fields must be arrays"
          end

          existing = dest[field]
          next dest[field] = value if existing.nil?

          if existing.is_a?(Array) != value.is_a?(Array)
            raise UsageError, "#{path}: Invalid event pattern field #{field}. Type mismatch between existing " \
              "pattern #{JSON.generate(existing)} and added pattern #{JSON.generate(value)}"
          end
          dest[field] = existing.is_a?(Array) ? dedupe(existing + value) : merge_pattern(existing, value)
        end
        dest
      end

      # De-duplication by JSON identity, first occurrence kept, order kept
      # (util.ts:45-50).
      def dedupe(list)
        seen = []
        list.reject do |item|
          json = JSON.generate(item)
          take = seen.include?(json)
          seen << json unless take
          take
        end
      end

      def stringify_keys(pattern)
        pattern.to_h { |key, value| [ key.to_s, value ] }
      end
    end
  end
end
