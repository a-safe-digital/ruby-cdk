# frozen_string_literal: true

require_relative "ports"

module RubyCdk
  module Deploy
    # What a deploy or a destroy may do.
    class DeployOptions
      attr_reader :parameters, :tags, :yes, :no_execute, :on_failure, :no_rollback, :outputs_file, :account

      def initialize(parameters: {}, tags: {}, yes: false, no_execute: false, on_failure: :delete, no_rollback: false, outputs_file: nil, account: nil)
        @parameters = parameters
        @tags = tags
        @yes = yes
        @no_execute = no_execute
        @on_failure = on_failure
        @no_rollback = no_rollback
        @outputs_file = outputs_file
        @account = account
      end
    end

    # What came out of a deploy or a destroy.
    class DeployResult
      OUTCOMES = %i[deployed no_changes not_executed rejected failed].freeze

      attr_reader :stack_name, :stack_id, :outcome, :changes, :outputs, :exit_code

      def initialize(stack_name:, outcome:, stack_id: nil, changes: [], outputs: {}, exit_code: 0)
        raise ArgumentError, "unknown outcome #{outcome.inspect}" unless OUTCOMES.include?(outcome)

        @stack_name = stack_name
        @stack_id = stack_id
        @outcome = outcome
        @changes = changes
        @outputs = outputs
        @exit_code = exit_code
      end
    end

    # Deploys stacks through change sets and destroys them. Talks to AWS only
    # through the two ports.
    class Deployer
      def initialize(client:, store:, output:)
        raise NotImplementedError, "Wave 1, track B"
      end

      def deploy(stack:, template:, identity:, options:)
        raise NotImplementedError, "Wave 1, track B"
      end

      def destroy(stack_name:, identity:, options:)
        raise NotImplementedError, "Wave 1, track B"
      end
    end
  end
end
