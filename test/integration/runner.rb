# frozen_string_literal: true

# The gem is on the load path by the time this file is read: `rake
# integration` loads it first, and the suite's test_helper does too.

module Integration
  # The bookkeeping of WF-5: what a run owes after it has deployed and before
  # it may claim to have left nothing behind. Everything goes through the
  # CloudFormation port, so a test gives it a fake and no client is ever built.
  #
  #   - before a stack is deleted, its ID is recorded, because a deleted stack
  #     is listed by ID only;
  #   - afterwards, the stacks with the integration prefix are listed through
  #     the port, and one still there fails the run;
  #   - then the resources of every deleted stack are listed by its ID, and
  #     anything CloudFormation skipped deleting is reported by its physical
  #     ID, so that a person can decide what to do about it. Nothing here ever
  #     deletes a physical resource by hand, and there is no sweeper in this
  #     wave (WF-5 rule 6 is Wave 3's).
  class Runner
    PREFIX = "ruby-cdk-it-"

    # What CloudFormation answers for a resource it deleted. Anything else it
    # can still name — a skipped one, DELETE_SKIPPED, first of all — is
    # reported: that is a resource the stack left behind.
    DELETED = %w[DELETE_COMPLETE].freeze

    attr_reader :destroyed

    # log is where the run's own lines go. `rake integration` gives it standard
    # output; a test gives it a buffer.
    def initialize(client:, log: $stdout)
      @client = client
      @log = log
      # name => ID, in the order the deletions were asked for.
      @destroyed = {}
    end

    # The App options every integration app is built with (WF-5 rule 3, and
    # architecture §7: the teardown must leave nothing behind). env is the
    # guard's env.
    def app_options(env)
      { env:, stack_name_prefix: PREFIX, stateful_default: :delete }
    end

    # Deletes one stack, by its ID, and records the ID first. The ID, not the
    # name, is what still names the stack once it is deleted, and what the
    # audit lists its resources by.
    def destroy(name)
      info = @client.stack_info(name)
      unless info&.id
        @log.puts("integration: #{name} is not in CloudFormation, so there is nothing to delete")
        return nil
      end

      @destroyed[name] = info.id
      @log.puts("integration: deleting #{name} (#{info.id})")
      @client.delete_stack(info.id)
      info.id
    end

    # The checks of a run that claims to have left nothing behind. Raises what
    # failed; a run that passes prints nothing but the report of a clean sweep.
    # Called after the teardown, whatever the run itself did.
    def audit
      leftovers = leftover_stacks
      unless leftovers.empty?
        raise RubyCdk::PreconditionError, "The run left #{leftovers.length} stack(s) with the prefix #{PREFIX} behind: " \
          "#{leftovers.map { |stack| name_of(stack) }.join(", ")}. Delete what is left in the CloudFormation console, " \
          "or with `ruby-cdk destroy`, before running the integration again."
      end

      skipped = skipped_resources
      unless skipped.empty?
        raise RubyCdk::PreconditionError, "CloudFormation skipped deleting #{skipped.length} resource(s) of the stacks " \
          "this run deleted: #{skipped.map { |resource| "#{field_of(resource, :logical_id)} (#{field_of(resource, :physical_id)})" }.join(", ")}. " \
          "A resource is skipped when its DeletionPolicy keeps it, and the console names how to delete it. " \
          "Nothing here deletes a physical resource by hand (WF-5)."
      end

      @log.puts("integration: nothing left behind: #{destroyed.length} stack(s) deleted, every resource deleted with them")
      true
    end

    private

    # The stacks with the prefix that the port still names. The port lists every
    # stack that is not deleted; the prefix is this runner's to apply.
    def leftover_stacks
      Array(@client.list_stacks).select do |stack|
        name = name_of(stack)
        name.nil? || name.start_with?(PREFIX)
      end
    end

    # The resources of the deleted stacks that CloudFormation did not delete.
    def skipped_resources
      destroyed.values.flat_map do |id|
        Array(@client.list_resources(id)).reject { |resource| DELETED.include?(status_of(resource)) }
      end
    end

    # The port's stacks arrive as name, id and status; whether they are read
    # by a key or by a method is the adapter's to settle, so both are read.
    def name_of(stack)
      field_of(stack, :name) || field_of(stack, :id)
    end

    def status_of(resource)
      field_of(resource, :status)
    end

    def field_of(object, name)
      if object.respond_to?(:[])
        object[name] || object[name.to_s]
      else
        object.public_send(name)
      end
    end
  end
end
