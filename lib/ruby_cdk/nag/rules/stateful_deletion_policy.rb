# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # RC-STATE-001. A stateful resource is compliant when its DeletionPolicy
      # is not Delete: deleting the stack must not destroy its data.
      #
      # This rule is this gem's own. Neither cdk-nag
      # (da5bed77c1b08e584e3de2d67534c76871af957f) nor cfn-nag
      # (8b5f03da74202ba323a145e9d037ddce6cab9dec) reads DeletionPolicy. It
      # states, for a template as it is written, the safe default of
      # architecture section 7 (D-007), which synthesis applies for its own
      # templates.
      #
      # The resource types are the stateful ones, given by the configuration
      # (Config#stateful_types), so that the list is the same everywhere in the
      # tool. applies_to is therefore not declared.
      #
      # What is not reported: a stateful resource with no DeletionPolicy at
      # all, which CloudFormation also deletes. The wave card's rule is the
      # written policy "Delete"; synthesis never leaves a stateful resource
      # without one.
      class StatefulDeletionPolicy < Rule
        id "RC-STATE-001"
        description "Stateful resource is not deleted with its stack"
        severity :high

        DELETION_POLICY = "DeletionPolicy"
        DELETE = "Delete"

        def applicable?
          config.stateful_types.include?(type)
        end

        def audit
          check(DELETION_POLICY) do
            violate(DELETION_POLICY, "is a stateful resource with DeletionPolicy Delete: retaining it keeps its data when the stack is deleted") if values.string(DELETION_POLICY) == DELETE
          end
        end
      end
    end
  end
end
