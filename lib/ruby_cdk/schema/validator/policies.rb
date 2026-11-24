# frozen_string_literal: true

require_relative "rule"
require_relative "scans"
require_relative "template"

module RubyCdk
  module Validation
    module Rules
      # V15: a resource type that holds data, deleted with the stack: DeletionPolicy is
      # Delete on a stateful type. A warning, because the choice is the user's to make.
      #
      # The list of stateful types is core's (core/stateful.rb, architecture §7), and the
      # validation component does not depend on core: the list is given when the rule is
      # built, and without it the rule is not built at all rather than checking nothing in
      # silence.
      class StatefulDeletion < Rule
        rule "V15"

        # [ types ] with the types architecture §7 retains.
        def initialize(types:)
          @types = Array(types).map(&:to_s)
        end

        def call(context)
          issues = []
          Scans::Resources.each(context) do |name, body, path|
            type = Template.resource_type(body)
            next unless @types.include?(type) && deletes?(body["DeletionPolicy"])

            issues << warning(path + [ "DeletionPolicy" ], "#{type} #{name} holds data, and DeletionPolicy is Delete: it goes with the stack",
              hint: "leave deletion_policy: out to retain it, or pass deletion_policy: :retain or :snapshot")
          end
          issues
        end

        private

        # True when the policy is Delete, or an Fn::If that can resolve to Delete.
        def deletes?(policy)
          return policy == "Delete" unless Template.function?(policy, "Fn::If") && policy["Fn::If"].is_a?(Array)

          policy["Fn::If"][1, 2].any? { |branch| deletes?(branch) }
        end
      end
    end
  end
end
