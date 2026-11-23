# frozen_string_literal: true

module RubyCdk
  module Deploy
    ChangeSet = Struct.new(:id, :status, :status_reason, :execution_status, :changes, keyword_init: true)
    Change = Struct.new(:action, :logical_id, :resource_type, :replacement, :detail, keyword_init: true)
    Event = Struct.new(:resource_status, :logical_id, :resource_type, :status_reason, :timestamp, keyword_init: true)
    StackResource = Struct.new(:logical_id, :status, :physical_id, keyword_init: true)
    Identity = Struct.new(:account, :region, :arn, keyword_init: true)
    StackInfo = Struct.new(:name, :id, :status, :outputs, :termination_protection, keyword_init: true)

    # What stack_state answers.
    #
    #   :absent            no such stack, or DELETE_COMPLETE: create it
    #   :review            REVIEW_IN_PROGRESS: a change set was never executed; create it again
    #   :stable            *_COMPLETE and not one of the two below: update it
    #   :rollback_complete the creation failed and rolled back: delete it, then create it
    #   :rollback_failed   a rollback is waiting to be continued: refuse
    #   :busy              an operation is running: refuse
    STACK_STATES = %i[absent review stable rollback_complete rollback_failed busy].freeze

    # How the engine talks to a person, or to --json and --quiet.
    module Output
      def target(account:, region:, profile:)
        Kernel.raise NotImplementedError
      end

      def changes(list)
        Kernel.raise NotImplementedError
      end

      # Asks a yes-or-no question. Returns true for yes.
      def ask(question)
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

      def create_change_set(name, change_set_name, template:, change_set_type:, parameters:, tags:, capabilities:, on_stack_failure: nil)
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

      def events(name_or_id, after:)
        Kernel.raise NotImplementedError
      end

      def get_template(name)
        Kernel.raise NotImplementedError
      end

      def update_termination_protection(name, enabled:)
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
