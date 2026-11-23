# frozen_string_literal: true

require_relative "../errors"

module RubyCdk
  module Deploy
    # The errors the engine raises on purpose, one per situation, each a
    # subclass of the class in errors.rb that carries its exit code. The base
    # class is what a component that did not raise the error can know, so the
    # command line and the engine rescue by it.

    # Exit 1. The credentials are for another account or region than the stack's env.
    class TargetMismatch < RubyCdk::PreconditionError; end

    # Exit 1. --account names an account other than the one the credentials are for.
    class AccountMismatch < RubyCdk::PreconditionError; end

    # Exit 1. An unattended deploy (--yes) of a stack without env, and no --account.
    class AccountRequired < RubyCdk::UsageError; end

    # Exit 1. No account could be resolved from the credentials.
    class AccountUnresolved < RubyCdk::PreconditionError; end

    # Exit 1. An operation is already running on the stack.
    class StackBusy < RubyCdk::PreconditionError; end

    # Exit 1. The stack is in a state that has to be repaired before anything else.
    class StackNeedsRepair < RubyCdk::PreconditionError; end

    # Exit 1. A CloudFormation status this engine does not know how to place.
    class UnknownStackStatus < RubyCdk::PreconditionError; end

    # Exit 1. The template is not the JSON this engine sends to CloudFormation.
    class InvalidTemplate < RubyCdk::PreconditionError; end

    # Exit 1. The template is too large to go inline and nothing else places it yet.
    class TemplateTooLarge < RubyCdk::PreconditionError; end

    # Exit 1. A parameter of the template has neither a value nor a default.
    class ParametersMissing < RubyCdk::UsageError; end

    # Exit 1. destroy was asked to delete a stack that is protected.
    class DestroyRefused < RubyCdk::PreconditionError; end

    # Exit 1. A wait reached its overall limit.
    class WaitTimedOut < RubyCdk::PreconditionError; end

    # Exit 3. CloudFormation rejected the change set, or did not create it.
    class ChangeSetFailed < RubyCdk::ChangeSetRejected; end

    # Exit 4. Approval was refused, or needed and not given.
    class ApprovalRequired < RubyCdk::ApprovalRefused; end

    # The exit code of section 14 for an error raised on purpose. Anything that
    # is not a RubyCdk::Error is a bug or an unexpected failure, and also exits 1.
    def self.exit_code_for(error)
      case error
      when RubyCdk::RulesFailed then 6
      when RubyCdk::DeploymentFailed then 5
      when RubyCdk::ApprovalRefused then 4
      when RubyCdk::ChangeSetRejected then 3
      when RubyCdk::ValidationError then 2
      else 1
      end
    end
  end
end
