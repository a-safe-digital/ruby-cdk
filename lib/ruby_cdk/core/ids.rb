# frozen_string_literal: true

require_relative "../errors"
require_relative "elements"

module RubyCdk
  module Core
    # The id rules of the tree, and how a resource's logical ID follows from the
    # ids around it (architecture §3, D-004 and D-029).
    module Ids
      # A logical ID in a template: letters and digits, nothing else.
      LOGICAL_ID_PATTERN = /\A[A-Za-z0-9]+\z/

      # The longest a logical ID can be: CloudFormation's limit for the name of
      # a parameter, a resource, an output or a mapping. Construct::MAX_ID_LENGTH
      # is this number: an id is a logical ID when it sits in a Stack.
      MAX_LOGICAL_ID_LENGTH = 255

      module_function

      # Raises UsageError unless id can name a construct: a String or a Symbol
      # of 1 to Construct::MAX_ID_LENGTH letters, digits, "_" or "-". scope,
      # when given, names the parent in the message. Returns the id as a String.
      def validate_id!(id, scope: nil)
        where = scope ? " under #{scope.path}" : ""
        unless id.is_a?(String) || id.is_a?(Symbol)
          Kernel.raise UsageError, "The id of a construct#{where} must be a String or a Symbol, got #{id.inspect}"
        end

        name = id.is_a?(Symbol) ? id.name : id
        if name.length > Construct::MAX_ID_LENGTH
          Kernel.raise UsageError, "The id \"#{name[0, 32]}...\"#{where} is longer than #{Construct::MAX_ID_LENGTH} characters"
        end
        unless Construct::ID_PATTERN.match?(name)
          Kernel.raise UsageError, "The id #{name.inspect}#{where} is not valid: an id holds letters, digits, \"_\" and \"-\", and at least one of them"
        end

        name
      end

      # Raises UsageError unless name can be the logical ID of an element of a
      # template, a parameter, an output, a mapping, a condition or a resource:
      # what rule V2 asks of it. where names the element and its id, as
      # 'App/blog: the output "table_name"'. Returns name.
      def validate_logical_id!(name, where:)
        problem = logical_id_message(name)
        Kernel.raise UsageError, "#{where}: #{problem}" if problem

        name
      end

      # The whole of what is wrong with name as a logical ID, in the words of
      # rule V2, or nil when nothing is: the fault, and how to write it instead.
      # A name too long has no way out to suggest, so the fault stands alone.
      def logical_id_message(name)
        fault = logical_id_fault(name)
        return nil unless fault
        return fault if name.length > MAX_LOGICAL_ID_LENGTH

        "#{fault}. #{logical_id_way_out(name)}"
      end

      # The fault alone, as rule V2 states it: the characters, or the length.
      def logical_id_fault(name)
        if name.length > MAX_LOGICAL_ID_LENGTH
          "the logical ID \"#{name[0, 32]}...\" is longer than #{MAX_LOGICAL_ID_LENGTH} characters"
        elsif LOGICAL_ID_PATTERN.match?(name)
          nil
        else
          "the logical ID #{name.inspect} must hold letters and digits only"
        end
      end

      # How to write it instead, for a logical ID that holds something else
      # than letters and digits.
      def logical_id_way_out(name)
        "CloudFormation takes no \"_\", \"-\" or \".\" in a logical ID: write #{spelled_without_punctuation(name)}"
      end

      # The logical ID of a node: the ids of the enclosing constructs, from the
      # Stack down to the node, joined. A node directly in a Stack keeps its own
      # id; `Api.new(stack, "Api")` creating `Role` gives `ApiRole`.
      def logical_id(node)
        return "" if node.is_a?(Stack) || node.is_a?(App) || !node.is_a?(Construct)

        "#{logical_id(node.scope)}#{node.id}"
      end

      # The logical ID a reference stands for: a String, a Symbol, a resource
      # or a parameter of a Stack. what names the call in the message, as
      # 'resource "Table" in App/blog: depends_on'.
      def logical_id_of(target, what)
        return target if target.is_a?(String)
        return target.name if target.is_a?(Symbol)
        return target.logical_id if target.respond_to?(:logical_id)

        Kernel.raise UsageError, "#{what} takes a resource, a parameter or a logical ID, got #{target.inspect}"
      end

      # The name a `condition:` stands for: a String, a Symbol or a condition the
      # stack declared. nil stays nil. what names the call in the message.
      def condition_name(condition, what)
        return nil if condition.nil?
        return condition if condition.is_a?(String)
        return condition.name if condition.is_a?(Symbol) || condition.is_a?(Condition)

        Kernel.raise UsageError, "#{what} takes a condition the stack declared, or its name, got #{condition.inspect}"
      end

      # "my_table" as "MyTable".
      def spelled_without_punctuation(name)
        name.split(/[^A-Za-z0-9]+/).map(&:capitalize).join
      end
      private_class_method :spelled_without_punctuation
    end
  end
end
