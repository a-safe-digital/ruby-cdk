# frozen_string_literal: true

module RubyCdk
  module Deploy
    ChangeSet = Struct.new(:id, :status, :status_reason, :execution_status, :changes, keyword_init: true)
    Change = Struct.new(:action, :logical_id, :resource_type, :replacement, :detail, keyword_init: true)
    Event = Struct.new(:resource_status, :logical_id, :resource_type, :status_reason, :timestamp, keyword_init: true)
    StackResource = Struct.new(:logical_id, :status, :physical_id, keyword_init: true)
    Identity = Struct.new(:account, :region, :arn, keyword_init: true)
    StackInfo = Struct.new(:name, :id, :status, :outputs, :termination_protection, keyword_init: true)
    ListedStack = Struct.new(:name, :id, :status, keyword_init: true)

    # What stack_state answers.
    #
    #   :absent            no such stack, or DELETE_COMPLETE: create it
    #   :review            REVIEW_IN_PROGRESS: a change set was never executed; create it again
    #   :stable            *_COMPLETE and not one of the two below: update it
    #   :rollback_complete the creation failed and rolled back: delete it, then create it
    #   :rollback_failed   a rollback is waiting to be continued: refuse
    #   :busy              an operation is running: refuse
    STACK_STATES = %i[absent review stable rollback_complete rollback_failed busy].freeze

    # The state each CloudFormation stack status is in. This is the promise of
    # stack_state, so the table sits with the port: the adapter that answers
    # stack_state and the engine that acts on the answer read the same one.
    # The grouping is the CDK's (stack-status.ts in its CLI).
    module StackStatus
      IN_PROGRESS = "_IN_PROGRESS"
      REVIEW = "REVIEW_IN_PROGRESS"
      DELETED = "DELETE_COMPLETE"

      STATE = {
        DELETED => :absent,
        REVIEW => :review,
        "CREATE_COMPLETE" => :stable,
        "UPDATE_COMPLETE" => :stable,
        "UPDATE_ROLLBACK_COMPLETE" => :stable,
        "IMPORT_COMPLETE" => :stable,
        "IMPORT_ROLLBACK_COMPLETE" => :stable,
        # The CDK's isCreationFailure: only a delete is possible, then a new creation.
        "ROLLBACK_COMPLETE" => :rollback_complete,
        "ROLLBACK_FAILED" => :rollback_complete,
        # A rollback is waiting to be continued, for an update as for an import:
        # an IMPORT_COMPLETE stack whose update fails rolls back into
        # IMPORT_ROLLBACK_FAILED.
        "UPDATE_ROLLBACK_FAILED" => :rollback_failed,
        "CREATE_FAILED" => :rollback_failed,
        "UPDATE_FAILED" => :rollback_failed,
        "DELETE_FAILED" => :rollback_failed,
        "IMPORT_ROLLBACK_FAILED" => :rollback_failed
      }.freeze

      # The state of a stack status, or nil for a status this tool does not know.
      # nil is a stack that does not exist. REVIEW_IN_PROGRESS is looked up
      # before the rule for in-progress statuses, because it ends the same way.
      def self.state(status)
        return :absent if status.nil?
        return nil unless status.is_a?(String)

        STATE.fetch(status) { status.end_with?(IN_PROGRESS) ? :busy : nil }
      end
    end

    # How the engine talks to a person, or to --json and --quiet.
    module Output
      def target(account:, region:, profile:)
        Kernel.raise NotImplementedError
      end

      # capabilities are the ones the template needed; the change view says which.
      def changes(list, capabilities: nil)
        Kernel.raise NotImplementedError
      end

      # Asks a yes-or-no question. Returns true for yes.
      def ask(question)
        Kernel.raise NotImplementedError
      end

      # Asks the person to type text, exactly. Returns true only when they did.
      def confirm(text)
        Kernel.raise NotImplementedError
      end

      def event(event)
        Kernel.raise NotImplementedError
      end

      def outputs(hash)
        Kernel.raise NotImplementedError
      end

      def failure(detail)
        Kernel.raise NotImplementedError
      end

      def retained(list)
        Kernel.raise NotImplementedError
      end

      # Says what the engine is doing or about to do, when it is none of the above:
      # that a failed stack is being deleted, that a change set was left unexecuted.
      def announce(text)
        Kernel.raise NotImplementedError
      end
    end

    # The port to CloudFormation. Everything behind it is the AWS SDK, or a fake.
    module CfnClient
      def resolve_identity
        Kernel.raise NotImplementedError
      end

      def stack_state(name)
        Kernel.raise NotImplementedError
      end

      def stack_info(name)
        Kernel.raise NotImplementedError
      end

      # The parameters the stack was last deployed with: { parameter key => value }.
      def stack_parameters(name)
        Kernel.raise NotImplementedError
      end

      # The tags on the stack: an Array of { key:, value: }.
      def stack_tags(name)
        Kernel.raise NotImplementedError
      end

      # template is the JSON text of the template, sent inline; template_url,
      # when given, is the URL of the template placed in the bucket, and
      # template is nil then: CloudFormation takes one or the other, never
      # both (architecture §8).
      def create_change_set(name, change_set_name, template:, change_set_type:, parameters:, tags:, capabilities:, on_stack_failure: nil,
        template_url: nil)
        Kernel.raise NotImplementedError
      end

      # The direct update of a deployed stack, without a change set: the fast
      # path `deploy --hotswap` takes (architecture section 9). template is the
      # JSON text of the template, sent inline; template_url, when given, is
      # the URL of the template placed in the bucket, and template is nil
      # then: CloudFormation takes one or the other, never both (architecture
      # §8) -- the same contract create_change_set carries. The template is
      # the whole new one: CloudFormation updates what differs and needs the
      # rest to know what to keep.
      def update_stack(name, template:, parameters:, tags:, capabilities:, template_url: nil)
        Kernel.raise NotImplementedError
      end

      def describe_change_set(name, change_set_id)
        Kernel.raise NotImplementedError
      end

      def execute_change_set(name, change_set_id, disable_rollback: false, retain_except_on_create: true)
        Kernel.raise NotImplementedError
      end

      def delete_change_set(name, change_set_id)
        Kernel.raise NotImplementedError
      end

      def delete_stack(name)
        Kernel.raise NotImplementedError
      end

      def list_resources(name_or_id)
        Kernel.raise NotImplementedError
      end

      # Every stack that is not deleted.
      def list_stacks
        Kernel.raise NotImplementedError
      end

      # after is a Time: only the events newer than it, oldest first. nil asks for
      # the events of the operation in progress, leaving the moment to the client,
      # which knows the clock skew between this machine and AWS.
      def events(name_or_id, after:)
        Kernel.raise NotImplementedError
      end

      def get_template(name)
        Kernel.raise NotImplementedError
      end

      def update_termination_protection(name, enabled:)
        Kernel.raise NotImplementedError
      end

      # Optional. The events CloudFormation recorded while it validated a change
      # set that failed to be created. NotImplementedError, or any error, means
      # they cannot be read; the engine then reports the reason alone.
      def operation_events(name, change_set_id)
        Kernel.raise NotImplementedError
      end
    end

    # The port to S3. Every call takes the expected bucket owner.
    module ObjectStore
      # :mine, :foreign or :absent
      def bucket_state(name, expected_owner:)
        Kernel.raise NotImplementedError
      end

      def object_exists?(bucket, key, expected_owner:)
        Kernel.raise NotImplementedError
      end

      def put(bucket, key, body:, expected_owner:)
        Kernel.raise NotImplementedError
      end
    end
  end
end
