# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "../lazy"
require_relative "../core/elements"
require_relative "../core/stateful"
require_relative "serializer"

module RubyCdk
  module Synth
    # The resolve phase of architecture §5. The live tree of one Stack becomes
    # a plain template: every Lazy is evaluated here, once, and nothing the user
    # wrote is changed, because the template is a parallel structure of new
    # arrays and hashes.
    #
    # A value the model of §4 cannot write does not stop the phase. It is
    # reported as an issue under VALUE_RULE and a placeholder stands in its
    # place, so that one synthesis reports every problem at once.
    class Resolver
      # The rule id of an issue from the value model. The rules of §6 are numbered from V1.
      VALUE_RULE = "V0"

      # What a nil property leaves behind: nothing.
      OMIT = Object.new.freeze

      # What stands in the template for a value that was rejected. A template
      # that holds one is never written.
      PLACEHOLDER = "<not a value>".freeze

      ISO_HINT = "for example time.utc.iso8601".freeze

      def initialize(stack, issues: [])
        @stack = stack
        @issues = issues
        @location = []
      end

      # The whole template of the stack.
      def call
        template = { "AWSTemplateFormatVersion" => Serializer::FORMAT_VERSION }
        template["Description"] = @stack.description if @stack.description
        template["Parameters"] = section("Parameters", @stack.parameters) { |parameter| parameter_body(parameter) }
        template["Mappings"] = section("Mappings", @stack.mappings) { |mapping| pairs(mapping.hash) }
        template["Conditions"] = section("Conditions", @stack.conditions) { |condition| value(condition.fn) }
        template["Resources"] = resources
        template["Outputs"] = section("Outputs", @stack.outputs) { |output| output_body(output) }
        template["Metadata"] = at("Metadata") { pairs(@stack.metadata) } unless @stack.metadata.empty?
        template.compact
      end

      # One value, the way the template holds it. Raises ValidationError when
      # it cannot be written.
      def resolve(item)
        resolved = value(item)
        raise ValidationError.new(@issues) unless @issues.empty?

        resolved.equal?(OMIT) ? nil : resolved
      end

      private

      # --- the sections
      #
      # The attributes of a parameter and of an output follow the order in
      # which the contract's signature names them; the serializer orders the
      # sections and the attributes of a resource.

      # A section built from what the stack declared, in declaration order.
      # nil when it declared nothing.
      def section(name, declarations)
        return nil if declarations.empty?

        at(name) { declarations.to_h { |key, element| [ key, at(key) { yield(element) } ] } }
      end

      def resources
        declared = @stack.resources
        return nil if declared.empty?

        at("Resources") { declared.to_h { |resource| [ resource.logical_id, at(resource.logical_id) { resource_body(resource) } ] } }
      end

      def parameter_body(parameter)
        body = { "Type" => parameter.type }
        at("Default") { body["Default"] = value(parameter.default) } unless parameter.default.nil?
        body["Description"] = parameter.description if parameter.description
        at("AllowedValues") { body["AllowedValues"] = value(parameter.allowed_values) } if parameter.allowed_values
        body["NoEcho"] = true if parameter.no_echo
        body
      end

      def output_body(output)
        body = {}
        at("Value") do
          resolved = value(output.value)
          if resolved.equal?(OMIT)
            report("the output has no value", hint: "value: is nil, or resolves to nil")
          else
            body["Value"] = resolved
          end
        end
        body["Description"] = output.description if output.description
        body["Export"] = { "Name" => @stack.export_name(output.id) } if output.export
        body["Condition"] = output.condition if output.condition
        body
      end

      def resource_body(resource)
        body = { "Type" => resource.type }
        body["DependsOn"] = resource.depends_on unless resource.depends_on.empty?
        body["Condition"] = resource.condition if resource.condition
        body["Metadata"] = at("Metadata") { pairs(resource.metadata) } unless resource.metadata.empty?
        deletion_policy, update_replace_policy = policies(resource)
        body["DeletionPolicy"] = deletion_policy if deletion_policy
        body["UpdateReplacePolicy"] = update_replace_policy if update_replace_policy
        unless resource.properties.empty?
          at("Properties") do
            properties = pairs(resource.properties)
            body["Properties"] = properties unless properties.empty?
          end
        end
        body
      end

      # [DeletionPolicy, UpdateReplacePolicy].
      #
      # deletion_policy: is the CDK's removal policy: it sets both, as
      # applyRemovalPolicy does. update_replace_policy: replaces the second
      # alone. With neither, a stateful type gets what architecture §7 gives it
      # under the stack's default, and any other type gets nothing.
      def policies(resource)
        defaults = Core::Stateful.policies_for(resource.type, default: @stack.stateful_default)
        given = resource.deletion_policy ? Core::Stateful.pair(resource.deletion_policy) : [ nil, nil ]

        [
          given[0] || defaults&.first,
          resource.update_replace_policy || given[1] || defaults&.last
        ]
      end

      # --- the value model (architecture §4)

      # A value by the rules of the model, or OMIT for a nil.
      def value(item)
        case item
        when String, Integer
          item
        when Float
          item.finite? ? item : reject("Infinity and NaN are not values")
        when true, false
          item
        when nil
          OMIT
        when Symbol
          item.name
        when Hash
          hash_value(item)
        when Array
          array_value(item)
        when Lazy
          lazy_value(item)
        when Time
          reject("a Time is not a value: write an ISO 8601 string", hint: ISO_HINT)
        when Proc
          reject("a Proc is not a value: a Proc is never called for you", hint: "wrap it in RubyCdk::Lazy.new { ... } when it should run at synthesis")
        when Construct
          construct_value(item)
        when Core::Element
          reject("the #{kind_of(item)} #{item.id} of the stack is not a value", hint: "Fn.ref takes a parameter, Fn.if a condition and Fn.find_in_map a mapping")
        else
          other_value(item)
        end
      end

      def hash_value(hash)
        simplify_join(pairs(hash))
      end

      def array_value(array)
        array.map.with_index do |item, index|
          at("[#{index}]") do
            resolved = value(item)
            next resolved unless resolved.equal?(OMIT)

            reject("nil is not a value inside an array", hint: "remove the nil entries with compact")
          end
        end
      end

      # The Lazy's value. A RubyCdk::Error raised while the block runs, as an
      # asset whose directory is missing, is an issue like any other, so that
      # one synthesis reports every problem at once. Anything else is a bug in
      # the block and leaves with its backtrace.
      def lazy_value(lazy)
        resolved =
          begin
            lazy.resolve(@stack)
          rescue RubyCdk::Error => e
            return reject("#{e.message} (a Lazy at this place could not be evaluated)")
          end
        value(resolved)
      end

      def construct_value(construct)
        if construct.respond_to?(:logical_id)
          reject("the resource #{construct.path} is not a value: did you mean `Fn.ref(...)`?",
            hint: "Fn.ref(resource) writes its Ref, and Fn.get_att(resource, \"Arn\") an attribute")
        else
          reject("#{construct.path} is a construct, and a construct is not a value")
        end
      end

      def other_value(item)
        if date?(item)
          reject("a #{item.class} is not a value: write an ISO 8601 string", hint: ISO_HINT)
        elsif asset?(item)
          reject("a zipped asset is not a value: use `.s3_location`, `.bucket` or `.key`")
        else
          reject("#{article(item.class)} #{item.class} is not a value: a template holds strings, numbers, booleans, arrays and hashes")
        end
      end

      def date?(item)
        defined?(::Date) && item.is_a?(::Date)
      end

      # Anything that answers what a zipped asset answers. Which component
      # defines that class is not this component's business.
      def asset?(item)
        item.respond_to?(:s3_location) && item.respond_to?(:bucket) && item.respond_to?(:key)
      end

      def kind_of(element)
        element.class.name.split("::").last.downcase
      end

      def article(klass)
        klass.name.start_with?("A", "E", "I", "O", "U") ? "an" : "a"
      end

      # --- helpers

      # A Hash whose keys are Strings and whose values are resolved. A nil
      # value leaves its key out.
      def pairs(hash)
        hash.each_with_object({}) do |(key, item), out|
          name = key_name(key)
          resolved = at(name) { value(item) }
          out[name] = resolved unless resolved.equal?(OMIT)
        end
      end

      def key_name(key)
        return key if key.is_a?(String)
        return key.name if key.is_a?(Symbol)

        report("a Hash key must be a String or a Symbol, got #{key.inspect}")
        key.to_s
      end

      # An Fn::Join whose list is wholly known becomes the shortest expression
      # that says the same, as it does when the CDK resolves a template.
      def simplify_join(hash)
        return hash unless hash.size == 1 && hash.key?("Fn::Join")

        delimiter, list = hash["Fn::Join"]
        return hash unless list.is_a?(Array)

        values = Fn.minimal_join(delimiter, list)
        values.one? ? values.first : { "Fn::Join" => [ delimiter, values ] }
      end

      # Reports an issue and answers the placeholder that stands in the template.
      def reject(message, hint: nil)
        report(message, hint:)
        PLACEHOLDER
      end

      def report(message, hint: nil)
        @issues << Issue.new(rule: VALUE_RULE, path: location, message:, hint:)
      end

      def at(segment)
        @location << segment
        yield
      ensure
        @location.pop
      end

      # Where we are in the template, as "Resources.Table.Properties.KeySchema[0].KeyType".
      def location
        @location.each_with_object(+"") do |segment, text|
          next text << segment if segment.start_with?("[")

          text << "." unless text.empty?
          text << segment
        end
      end
    end
  end
end
