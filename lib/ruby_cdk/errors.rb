# frozen_string_literal: true

module RubyCdk
  # Base class of every error this gem raises on purpose.
  class Error < StandardError; end

  # Exit 1: the command was asked to do something it cannot.
  class UsageError < Error; end

  # Exit 1: a precondition failed, such as an account mismatch or a busy stack.
  class PreconditionError < Error; end

  # Exit 3: CloudFormation rejected the change set.
  class ChangeSetRejected < Error; end

  # Exit 4: approval was refused, or needed and not given.
  class ApprovalRefused < Error; end

  # Exit 5: the stack operation failed or rolled back.
  class DeploymentFailed < Error; end

  # Exit 6: security rules above the threshold failed.
  class RulesFailed < Error; end

  # One problem found by a validation rule. path is the location inside the stack.
  Issue = Data.define(:rule, :path, :message, :hint)

  # Exit 2: local validation failed. Every issue is reported at once.
  class ValidationError < Error
    attr_reader :issues

    # issues: an Array of Issue, or of strings.
    def initialize(issues)
      @issues = issues.freeze
      super(issues.map { |issue| issue.is_a?(Issue) ? "#{issue.rule} #{issue.path}: #{issue.message}" : issue.to_s }.join("\n"))
    end
  end
end
