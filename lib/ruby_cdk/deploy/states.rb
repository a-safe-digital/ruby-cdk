# frozen_string_literal: true

require_relative "errors"

module RubyCdk
  module Deploy
    # The six states of a stack, read from its CloudFormation status.
    #
    # The table itself is in the port (StackStatus), because the adapter that
    # answers stack_state needs it too. This is the engine's reading of it,
    # which places every status it knows and refuses the rest: a status this
    # tool cannot place is never guessed at.
    module States
      # What has to happen before a stack in :rollback_failed can be deployed
      # again. Each path is the one AWS documents for that status, read in the
      # CloudFormation User Guide on 2026-11-23: "Stack failure options",
      # "Continue rolling back an update" and "Delete a stack from the
      # CloudFormation console".
      REPAIR = {
        "CREATE_FAILED" =>
          "Roll the stack back to its last known stable state: Roll back in the CloudFormation console, or the RollbackStack API. " \
          "A stack whose creation failed has no stable state, so the rollback deletes it, and the next deploy creates it again.",
        "UPDATE_FAILED" =>
          "Roll the stack back to its last known stable state: Roll back in the CloudFormation console, or the RollbackStack API.",
        "UPDATE_ROLLBACK_FAILED" =>
          "Continue the update rollback: in the CloudFormation console, on the Stacks page, choose the stack, " \
          "then Stack actions and Continue update rollback.",
        "DELETE_FAILED" =>
          "The stack could not be deleted. Fix the resources that blocked the deletion, then delete the stack again: " \
          "in the CloudFormation console, on the Stacks page, choose the stack, then Retry delete."
      }.freeze

      # The page that explains the failed states and what can be done about them.
      DOCS = "https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/stack-failure-options.html"

      # The state of a stack status, one of STACK_STATES. nil is a stack that
      # does not exist. A status that is neither in the table nor in progress is
      # an error: this tool does not know what to do with it, and says so.
      def self.classify(status)
        state = StackStatus.state(status)
        if state.nil?
          raise UnknownStackStatus, "CloudFormation reports the stack status #{status.inspect}, which this tool does not know how to place. " \
            "Nothing was changed. Look at the stack in the CloudFormation console, and report the status as a bug in ruby-cdk."
        end

        state
      end

      # The way out of a status in :rollback_failed, with what to do next.
      def self.repair_path(status)
        repair = REPAIR[status]
        return nil unless repair

        "#{repair}\nWhen the stack is back in a stable state, run the command again. #{DOCS}"
      end
    end
  end
end
