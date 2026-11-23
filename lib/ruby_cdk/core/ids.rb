# frozen_string_literal: true

module RubyCdk
  module Core
    # The id rules of the tree, and how a resource's logical ID follows from the
    # ids around it (architecture §3, D-004 and D-029).
    module Ids
      # A logical ID in a template: letters and digits, nothing else (rule V2).
      LOGICAL_ID_PATTERN = /\A[A-Za-z0-9]+\z/

      module_function

      # Raises UsageError unless id can name a construct: a String or a Symbol
      # of 1 to Construct::MAX_ID_LENGTH letters, digits, "_" or "-". scope,
      # when given, names the parent in the message. Returns the id as a String.
      def validate_id!(id, scope: nil)
        where = scope ? " under #{scope.path}" : ""
        unless id.is_a?(String) || id.is_a?(Symbol)
          raise UsageError, "The id of a construct#{where} must be a String or a Symbol, got #{id.inspect}"
        end

        name = id.is_a?(Symbol) ? id.name : id
        if name.length > Construct::MAX_ID_LENGTH
          raise UsageError, "The id \"#{name[0, 32]}...\"#{where} is longer than #{Construct::MAX_ID_LENGTH} characters"
        end
        unless Construct::ID_PATTERN.match?(name)
          raise UsageError, "The id #{name.inspect}#{where} is not valid: an id holds letters, digits, \"_\" and \"-\", and at least one of them"
        end

        name
      end

      # The logical ID of a node: the ids of the enclosing constructs, from the
      # Stack down to the node, joined. A node directly in a Stack keeps its own
      # id; `Api.new(stack, "Api")` creating `Role` gives `ApiRole`.
      def logical_id(node)
        ids = []
        current = node
        while current.is_a?(Construct) && !current.is_a?(Stack) && !current.is_a?(App)
          ids << current.id
          current = current.scope
        end
        ids.reverse.join
      end
    end
  end
end
