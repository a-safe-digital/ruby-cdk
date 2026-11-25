# frozen_string_literal: true

require "json"

module RubyCdk
  module Diff
    # CloudFormation intrinsics written the way a person reads them, the CDK's
    # renderIntrinsics (cloudformation-diff, lib/render-intrinsics.ts at
    # eca1b73d682d7763955bec30ab5dd52bbc4327b6): a Ref becomes ${LogicalId},
    # Fn::GetAtt becomes ${LogicalId.Attribute}, a literal Fn::Join is joined,
    # any other intrinsic is shown as its JSON, and AWS::NoValue disappears.
    # Not meant to parse back into a template; meant to be understood.
    module RenderIntrinsics
      module_function

      def call(value)
        case value
        when Array
          value.reject { |entry| no_value?(entry) }.map { |entry| call(entry) }
        when Hash
          if (intrinsic = intrinsic_of(value))
            return render_intrinsic(intrinsic)
          end

          value.each_with_object({}) do |(key, entry), rendered|
            rendered[key] = call(entry) unless no_value?(entry)
          end
        else
          value
        end
      end

      def render_intrinsic(intrinsic)
        fn, arguments = intrinsic
        case fn
        when "Ref" then "${#{call(arguments)}}"
        when "Fn::GetAtt"
          parts = arguments.is_a?(Array) ? arguments : arguments.to_s.split(".")
          "${#{parts.map { |part| call(part) }.join(".")}}"
        when "Fn::Join"
          separator, items = arguments.is_a?(Array) ? arguments : [ nil, arguments ]
          items.is_a?(Array) ? items.reject { |entry| no_value?(entry) }.map { |entry| call(entry) }.join(separator.to_s) : intrinsic_json(fn, arguments)
        else
          intrinsic_json(fn, arguments)
        end
      end

      def intrinsic_json(fn, arguments)
        JSON.generate({ fn => call(arguments) })
      end

      def intrinsic_of(value)
        keys = value.keys
        return nil unless keys.length == 1

        key = keys.first
        return nil unless key == "Ref" || key.start_with?("Fn::")

        [ key, value[key] ]
      end

      def no_value?(value)
        return false unless value.is_a?(Hash)

        value.keys == [ "Ref" ] && value["Ref"] == "AWS::NoValue"
      end
    end

    # One IAM policy statement, the CDK's Statement (cloudformation-diff,
    # lib/iam/statement.ts). Two statements are the same when everything they
    # say is the same, which is how the security view tells an added statement
    # from one that was already deployed.
    class Statement
      EFFECTS = %w[Allow Deny].freeze

      attr_reader :sid, :effect, :condition, :serialized, :resources, :actions, :principals

      # statement is the Hash of one statement, or a string when the template
      # carries something there that is not a statement Hash (the CDK keeps it
      # as a serialized intrinsic and shows it as it is).
      def initialize(statement)
        if statement.is_a?(String)
          @sid = nil
          @effect = "Unknown"
          @resources = Targets.new({}, nil, nil)
          @actions = Targets.new({}, nil, nil)
          @principals = Targets.new({}, nil, nil)
          @condition = nil
          @serialized = statement
        else
          map = statement || {}
          @sid = map["Sid"].is_a?(String) ? map["Sid"] : nil
          @effect = EFFECTS.include?(map["Effect"]) ? map["Effect"] : "Unknown"
          @resources = Targets.new(map, "Resource", "NotResource")
          @actions = Targets.new(map, "Action", "NotAction")
          @principals = Targets.new(map, "Principal", "NotPrincipal")
          @condition = map["Condition"]
          @serialized = nil
        end
      end

      # True when the two statements say exactly the same thing.
      def equal?(other)
        sid == other.sid && effect == other.effect && serialized == other.serialized &&
          resources.equal?(other.resources) && actions.equal?(other.actions) &&
          principals.equal?(other.principals) && condition == other.condition
      end

      # A statement broadens permissions when it grants something: it is a
      # positive Allow or a negative Deny. The CDK's isNegativeStatement.
      def negative?
        not_target = actions.not? || principals.not? || resources.not?
        effect == "Allow" ? not_target : !not_target
      end

      # The row of the security view's statement table, as the CDK's render:
      # one column each for the resource, the effect, the action, the
      # principal and the condition.
      def render
        return { resource: serialized, effect: "", action: "", principal: principals.render, condition: "" } if serialized

        {
          resource: resources.render,
          effect: effect,
          action: actions.render,
          principal: principals.render,
          condition: render_condition(condition)
        }
      end

      # The machine-readable statement (--json), as the CDK's _toJson.
      def to_h
        return { "serialized" => serialized } if serialized

        {
          "sid" => sid,
          "effect" => effect,
          "resources" => resources.to_h,
          "actions" => actions.to_h,
          "principals" => principals.to_h,
          "condition" => condition
        }.compact
      end

      # The CDK's parseLambdaPermission: what Lambda::Permission says, written
      # as the statement Lambda adds to the function's policy when the
      # permission is granted.
      def self.from_lambda_permission(properties)
        properties ||= {}
        statement = {
          "Effect" => "Allow",
          "Action" => properties["Action"],
          "Resource" => properties["FunctionName"]
        }
        principal = properties["Principal"]
        unless principal.nil?
          statement["Principal"] = if principal == "*"
            "*"
          elsif principal.match?(/\A\d{12}\z/)
            { "AWS" => "arn:aws:iam::#{principal}:root" }
          else
            { "Service" => principal }
          end
        end
        condition_of(properties, "SourceArn", "ArnLike", "AWS:SourceArn", statement)
        condition_of(properties, "SourceAccount", "StringEquals", "AWS:SourceAccount", statement)
        condition_of(properties, "EventSourceToken", "StringEquals", "lambda:EventSourceToken", statement)
        new(statement)
      end

      def self.condition_of(properties, property, operator, key, statement)
        return if properties[property].nil?

        statement["Condition"] ||= {}
        statement["Condition"][operator] = { key => properties[property] }
      end

      private_class_method :condition_of

      private

      # The condition column: the JSON of the condition, without the outermost
      # braces and the indentation, which is how the CDK renders it.
      def render_condition(condition)
        return "" if condition.nil? || (condition.is_a?(Hash) && condition.empty?)

        lines = JSON.pretty_generate(condition).split("\n")
        inner = lines[1...-1] || []
        inner.map { |line| line.delete_prefix("  ") }.join("\n")
      end
    end

    # The values of one field of a statement (Resource, Action, Principal),
    # the CDK's Targets: sorted, strings or NOT-strings, joined by newlines
    # when there are several.
    class Targets
      attr_reader :values

      # statement is the statement Hash, positive_key the field that grants and
      # negative_key the one that excludes (NotAction and friends).
      def initialize(statement, positive_key, negative_key)
        if negative_key && statement.key?(negative_key)
          @values = strings_of(statement[negative_key])
          @not = true
        else
          @values = negative_key ? strings_of(statement[positive_key]) : []
          @not = false
        end
        @values.sort!
      end

      def not?
        @not
      end

      # True when the two targets say the same things of the same kind.
      def equal?(other)
        @not == other.not? && values == other.values.sort
      end

      # The default the place of the statement gives the field: a field left
      # empty, or left as "*", takes it (the CDK's replaceEmpty and
      # replaceStar, which its statement defaults are written with).
      def replace_empty_or_star(value)
        values << value if values.empty?
        values.map! { |entry| entry == "*" ? value : entry }
        values.sort!
        self
      end

      def render
        @not ? values.map { |value| "NOT #{value}" }.join("\n") : values.join("\n")
      end

      def to_h
        { "not" => @not, "values" => values }
      end

      private

      # The CDK's forceListOfStrings: a string is one value, a list is its
      # elements flattened into strings, an object is its entries as
      # "key:Value", everything else is its string.
      def strings_of(value)
        case value
        when String then [ value ]
        when nil then []
        when Array then value.map { |entry| strings_of(entry).join(",") }
        when Hash
          value.flat_map { |key, entry| strings_of(entry).map { |entry_string| "#{key}:#{entry_string}" } }
        else [ value.to_s ]
        end
      end
    end
  end
end
