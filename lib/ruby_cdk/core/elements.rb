# frozen_string_literal: true

require_relative "../errors"

module RubyCdk
  module Core
    # Something a Stack declares under a name of its own, in a section other
    # than Resources: a parameter, a mapping, a condition or an output. It is a
    # handle: Fn.ref, Fn.if, Fn.find_in_map and `condition:` take it.
    class Element
      attr_reader :stack, :id

      def initialize(stack, id)
        @stack = stack
        @id = id
      end

      # Its name in the template.
      def logical_id
        id
      end
      alias name logical_id

      def to_s
        id
      end

      private

      # A String or a Symbol, as a String.
      def word(value, attribute)
        return value if value.is_a?(String)
        return value.name if value.is_a?(Symbol)

        raise UsageError, "#{stack.path}: #{id}.#{attribute} must be a String or a Symbol, got #{value.inspect}"
      end
    end

    # A Parameters entry. `type:` is a CloudFormation parameter type: "String",
    # "Number", "CommaDelimitedList", "List<Number>", or an AWS-specific one.
    class Parameter < Element
      attr_reader :type, :default, :description, :allowed_values, :no_echo

      def initialize(stack, id, type:, default:, description:, allowed_values:, no_echo:)
        super(stack, id)
        @type = word(type, "type")
        @default = default
        @description = description && word(description, "description")
        unless allowed_values.nil? || allowed_values.is_a?(Array)
          raise UsageError, "#{stack.path}: #{id}.allowed_values must be an Array, got #{allowed_values.inspect}"
        end

        @allowed_values = allowed_values
        @no_echo = no_echo ? true : false
      end
    end

    # A Mappings entry: a two-level hash.
    class Mapping < Element
      attr_reader :hash

      def initialize(stack, id, hash)
        unless hash.is_a?(Hash)
          raise UsageError, "#{stack.path}: mapping #{id.inspect} takes a Hash, got #{hash.inspect}"
        end

        super(stack, id)
        @hash = hash
      end
    end

    # A Conditions entry. fn is what a condition function returns: Fn.equals,
    # Fn.and_, Fn.not_ and so on.
    class Condition < Element
      attr_reader :fn

      def initialize(stack, id, fn)
        unless fn.is_a?(Hash)
          raise UsageError, "#{stack.path}: condition #{id.inspect} takes what Fn.equals, Fn.and_ or Fn.not_ return, got #{fn.inspect}"
        end

        super(stack, id)
        @fn = fn
      end
    end

    # An Outputs entry. export is true when its Export name is stack.export_name(id).
    class Output < Element
      attr_reader :value, :description, :export, :condition

      def initialize(stack, id, value:, description:, export:, condition:)
        if value.nil?
          raise UsageError, "#{stack.path}: output #{id.inspect} needs a value"
        end
        unless export == true || export == false
          raise UsageError, "#{stack.path}: output #{id.inspect} takes export: true or false, got #{export.inspect}"
        end

        super(stack, id)
        @value = value
        @description = description && word(description, "description")
        @export = export
        @condition = condition
      end
    end
  end
end
