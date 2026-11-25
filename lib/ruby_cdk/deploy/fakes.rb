# frozen_string_literal: true

require_relative "../deploy"
require_relative "states"

module RubyCdk
  module Deploy
    # In-memory stand-ins for the two ports and the output, for tests. Nothing
    # here reaches AWS, and nothing here needs a credential.
    #
    # The CloudFormation fake works the way the CDK's own tests do: answers are
    # scripted per operation and consumed in order, and every call the engine
    # made is kept for the assertions. Underneath that it keeps a small state,
    # so a test that needs nothing special writes almost nothing:
    #
    # - a stack registered with a status answers stack_state, stack_info,
    #   get_template, stack_parameters and stack_tags from it;
    # - creating a change set brings a new stack into REVIEW_IN_PROGRESS;
    # - executing a change set ends in the status the test chose
    #   (execute_result), CREATE_COMPLETE or UPDATE_COMPLETE by default;
    # - deleting a stack ends in DELETE_COMPLETE.
    #
    #   client = Fakes::CfnClient.new
    #   client.stack("blog", status: "ROLLBACK_COMPLETE")
    #   client.on(:describe_change_set, ChangeSet.new(status: "FAILED", status_reason: "wrong type"))
    #   out = Fakes::Output.new(approvals: false)
    #   error = assert_raises(RubyCdk::Deploy::ChangeSetFailed) do
    #     Deployer.new(client: client, store: Fakes::ObjectStore.new, output: out, poller: Poller.instant,
    #       operation_poller: Poller.instant).deploy(stack:, template:, identity: client.identity,
    #       options: DeployOptions.new(account: Fakes::CfnClient::ACCOUNT))
    #   end
    #   assert_equal %i[stack_state stack_info delete_stack stack_state create_change_set describe_change_set stack_info
    #                   operation_events delete_change_set stack_state delete_stack stack_state],
    #     client.operations
    module Fakes
      # One call the engine made: the operation, its positional arguments and its keywords.
      Call = Struct.new(:operation, :args, :kwargs, keyword_init: true)

      # A stack as the fake keeps it.
      Record = Struct.new(:name, :id, :status, :template, :parameters, :tags, :outputs, :termination_protection, :events,
        :resources, keyword_init: true)

      # A change set as the fake keeps it. empty marks one CloudFormation would
      # refuse: created for a stack whose template is already the new one.
      ChangeSetRecord = Struct.new(:id, :type, :template, :template_url, :parameters, :tags, :capabilities, :on_stack_failure,
        :empty, keyword_init: true)

      # The CloudFormation port, scripted.
      class CfnClient
        include RubyCdk::Deploy::CfnClient

        ACCOUNT = "111122223333"
        REGION = "eu-west-1"
        STACK_TYPE = "AWS::CloudFormation::Stack"

        attr_reader :calls, :executions, :identity
        # { change set id => ChangeSetRecord }, in the order they were created.
        attr_reader :change_sets

        # identity is what resolve_identity answers unless it is scripted.
        def initialize(identity: Identity.new(account: ACCOUNT, region: REGION, arn: "arn:aws:iam::#{ACCOUNT}:user/deployer"))
          @identity = identity
          @stacks = {}
          @scripts = Hash.new { |hash, operation| hash[operation] = [] }
          @calls = []
          @change_sets = {}
          @executions = []
          @tick = 0
          @execute_result = nil
        end

        # --- scripting

        # The next answers of an operation, in order. An answer is a value,
        # which is returned; an Exception, which is raised; or a callable, which
        # is called with the Call and answers what it returns. The last answer
        # repeats, which is what a poll needs.
        def on(operation, *answers)
          @scripts[operation].concat(answers)
          self
        end

        # Registers a stack as CloudFormation describes it. Registering a name
        # again keeps its ID and its events.
        def stack(name, status: "CREATE_COMPLETE", template: nil, parameters: {}, tags: [], outputs: {}, termination_protection: false,
          resources: [], id: nil)
          old = lookup(name)
          @stacks[name] = Record.new(
            name: name, id: id || old&.id || "arn:aws:cloudformation:#{REGION}:#{ACCOUNT}:stack/#{name}/id-#{next_number}",
            status: status, template: template, parameters: parameters, tags: tags, outputs: outputs,
            termination_protection: termination_protection, events: old&.events || [], resources: resources
          )
          self
        end

        # Adds an event to a stack's history, after the ones already there.
        # at is a Time; by default each event is a second later than the last.
        def emit(name, resource_status, logical_id: name, resource_type: STACK_TYPE, status_reason: nil, at: nil)
          stack(name, status: "CREATE_IN_PROGRESS") unless lookup(name)
          lookup(name).events << Event.new(
            resource_status: resource_status, logical_id: logical_id, resource_type: resource_type,
            status_reason: status_reason, timestamp: at || later
          )
          self
        end

        # The status a stack ends in when its change set is executed. nil is the
        # default: CREATE_COMPLETE for a creation, UPDATE_COMPLETE for an update.
        def execute_result(status)
          @execute_result = status
          self
        end

        # --- what the engine did

        # The operations, in the order they were called.
        def operations
          calls.map(&:operation)
        end

        def calls_to(operation)
          calls.select { |call| call.operation == operation }
        end

        # The keywords of each call of an operation.
        def kwargs_of(operation)
          calls_to(operation).map(&:kwargs)
        end

        def last(operation)
          calls_to(operation).last
        end

        def stack_record(name)
          lookup(name)
        end

        # --- the port

        def resolve_identity
          scripted(:resolve_identity) { @identity }
        end

        def stack_state(name)
          scripted(:stack_state, name) do
            record = lookup(name)
            record ? States.classify(record.status) : :absent
          end
        end

        def stack_info(name)
          scripted(:stack_info, name) do
            record = lookup(name)
            record && info_of(record)
          end
        end

        def stack_parameters(name)
          scripted(:stack_parameters, name) { lookup(name)&.parameters || {} }
        end

        def stack_tags(name)
          scripted(:stack_tags, name) { lookup(name)&.tags || [] }
        end

        def create_change_set(name, change_set_name, template:, change_set_type:, parameters:, tags:, capabilities:,
          on_stack_failure: nil, template_url: nil)
          scripted(:create_change_set, name, change_set_name, template: template, change_set_type: change_set_type,
            parameters: parameters, tags: tags, capabilities: capabilities, on_stack_failure: on_stack_failure,
            template_url: template_url) do
            id = "arn:aws:cloudformation:#{REGION}:#{ACCOUNT}:changeSet/#{change_set_name}/#{next_number}"
            record = lookup(name)
            # CloudFormation refuses a change set that would change nothing: the
            # set is created FAILED, with the reason (the CDK's own fake marks
            # it the same way, fake-cloudformation.ts). Nothing changes only
            # when the template, the parameters and the tags are all the same.
            # A template placed in the bucket cannot be compared here, so its
            # change set is never marked empty. A test that wants another
            # answer scripts it.
            new_parameters = pairs_of(parameters, record)
            unchanged = template_url.nil? && change_set_type == :update && record && record.template == template &&
              new_parameters == (record.parameters || {}) && tags == (record.tags || [])
            @change_sets[id] = ChangeSetRecord.new(id: id, type: change_set_type, template: template, template_url: template_url,
              parameters: new_parameters, tags: tags, capabilities: capabilities,
              on_stack_failure: on_stack_failure, empty: unchanged)
            bring_into_review(name, template, parameters, tags) if change_set_type == :create
            ChangeSet.new(id: id)
          end
        end

        def describe_change_set(name, change_set_id)
          scripted(:describe_change_set, name, change_set_id) do
            change_set = @change_sets[change_set_id]
            if change_set.nil?
              # A change set that is gone answers as a deleted one, as
              # CloudFormation answers for a deleted set.
              ChangeSet.new(id: change_set_id, status: "DELETE_COMPLETE")
            elsif change_set.empty
              ChangeSet.new(id: change_set_id, status: "FAILED",
                status_reason: "The submitted information didn't contain changes.", changes: [])
            else
              ChangeSet.new(id: change_set_id, status: "CREATE_COMPLETE", execution_status: "AVAILABLE",
                changes: [ Change.new(action: change_set.type == :update ? "Modify" : "Add", logical_id: "Bucket",
                  resource_type: "AWS::S3::Bucket", replacement: "False", detail: nil) ])
            end
          end
        end

        def execute_change_set(name, change_set_id, disable_rollback: false, retain_except_on_create: true)
          scripted(:execute_change_set, name, change_set_id, disable_rollback: disable_rollback,
            retain_except_on_create: retain_except_on_create) do
            @executions << { name: name, change_set_id: change_set_id, disable_rollback: disable_rollback,
              retain_except_on_create: retain_except_on_create }
            change_set = @change_sets[change_set_id]
            record = lookup(name)
            if change_set && record
              record.template = change_set.template
              record.parameters = change_set.parameters
              record.tags = change_set.tags
              record.status = @execute_result || (change_set.type == :create ? "CREATE_COMPLETE" : "UPDATE_COMPLETE")
            end
          end
        end

        def delete_change_set(name, change_set_id)
          scripted(:delete_change_set, name, change_set_id) { @change_sets.delete(change_set_id) }
        end

        # A stack protected from deletion is not deleted, as in CloudFormation.
        def delete_stack(name)
          scripted(:delete_stack, name) do
            record = lookup(name)
            if record
              refuse_protected(record)
              record.status = "DELETE_COMPLETE"
            end
          end
        end

        def list_resources(name_or_id)
          scripted(:list_resources, name_or_id) { lookup(name_or_id)&.resources || [] }
        end

        # Every registered stack that is not deleted.
        def list_stacks
          scripted(:list_stacks) do
            @stacks.values.reject { |record| record.status == StackStatus::DELETED }
              .map { |record| ListedStack.new(name: record.name, id: record.id, status: record.status) }
          end
        end

        def events(name_or_id, after:)
          scripted(:events, name_or_id, after: after) do
            (lookup(name_or_id)&.events || []).select { |event| after.nil? || event.timestamp > after }
          end
        end

        def get_template(name)
          scripted(:get_template, name) { lookup(name)&.template }
        end

        def update_termination_protection(name, enabled:)
          scripted(:update_termination_protection, name, enabled: enabled) do
            record = lookup(name)
            record.termination_protection = enabled if record
          end
        end

        # CloudFormation's own events are only ever scripted here.
        def operation_events(name, change_set_id)
          scripted(:operation_events, name, change_set_id) { [] }
        end

        private

        # Records the call, answers from the script when there is one, and
        # otherwise leaves it to the block.
        def scripted(operation, *args, **kwargs)
          @calls << Call.new(operation: operation, args: args, kwargs: kwargs)
          queue = @scripts[operation]
          if queue.any?
            answer = queue.length > 1 ? queue.shift : queue.first
            raise answer if answer.is_a?(Exception)
            return answer.call(Call.new(operation: operation, args: args, kwargs: kwargs)) if answer.respond_to?(:call)

            return answer
          end
          yield
        end

        def lookup(name_or_id)
          @stacks.each_value.find { |record| record.name == name_or_id || record.id == name_or_id }
        end

        # A CREATE change set is what brings a stack into existence, with nothing
        # in it yet, as in CloudFormation. A stack that does not exist, or was
        # deleted, comes into being with an ID of its own; one that is already
        # waiting in REVIEW_IN_PROGRESS keeps its ID and takes the new template.
        def bring_into_review(name, template, parameters, tags)
          record = lookup(name)
          fresh = record.nil? || record.status == StackStatus::DELETED
          stack(name, status: "REVIEW_IN_PROGRESS", template: template, parameters: pairs_of(parameters, fresh ? nil : record),
            tags: tags,
            id: fresh ? "arn:aws:cloudformation:#{REGION}:#{ACCOUNT}:stack/#{name}/id-#{next_number}" : nil,
            outputs: record&.outputs || {}, resources: record&.resources || [])
        end

        def info_of(record)
          StackInfo.new(name: record.name, id: record.id, status: record.status, outputs: record.outputs,
            termination_protection: record.termination_protection)
        end

        # The parameters of a change set as the stack keeps them: { key => value }.
        # A use_previous_value entry keeps what the stack has, which is how the
        # masked value of a NoEcho parameter goes back as it came.
        def pairs_of(parameters, record = nil)
          parameters.to_a.map do |pair|
            key = pair[:parameter_key] || pair["parameter_key"]
            if pair[:use_previous_value]
              [ key, record&.parameters&.dig(key) ]
            else
              [ key, pair[:parameter_value] || pair["parameter_value"] ]
            end
          end.to_h
        end

        def refuse_protected(record)
          return unless record.termination_protection

          raise RubyCdk::PreconditionError, "Stack #{record.name} is protected from deletion (termination protection)"
        end

        def next_number
          @tick += 1
        end

        def later
          @tick += 1
          Time.utc(2026, 1, 1) + @tick
        end
      end

      # The S3 port. Buckets have owners, and a call that names the wrong owner
      # is refused, which is what the owner check is for.
      class ObjectStore
        include RubyCdk::Deploy::ObjectStore

        attr_reader :calls
        # { [ bucket, key ] => body }
        attr_reader :objects

        def initialize
          @owners = {}
          @objects = {}
          @calls = []
        end

        # Creates a bucket owned by an account. owner defaults to the account of the CloudFormation fake.
        def bucket(name, owner: CfnClient::ACCOUNT)
          @owners[name] = owner
          self
        end

        def bucket_state(name, expected_owner:)
          record(:bucket_state, name, nil, expected_owner)
          owner = @owners[name]
          return :absent if owner.nil?

          owner == expected_owner ? :mine : :foreign
        end

        def object_exists?(bucket, key, expected_owner:)
          record(:object_exists?, bucket, key, expected_owner)
          check_owner(bucket, expected_owner)
          @objects.key?([ bucket, key ])
        end

        def put(bucket, key, body:, expected_owner:)
          record(:put, bucket, key, expected_owner)
          check_owner(bucket, expected_owner)
          @objects[[ bucket, key ]] = body
        end

        # The operations, in the order they were called.
        def operations
          calls.map(&:operation)
        end

        private

        # The state of a bucket without recording the question.
        def state_of(bucket, expected_owner)
          owner = @owners[bucket]
          return :absent if owner.nil?

          owner == expected_owner ? :mine : :foreign
        end

        def check_owner(bucket, expected_owner)
          state = state_of(bucket, expected_owner)
          return if state == :mine

          reason = state == :absent ? "does not exist" : "belongs to another account than #{expected_owner}"
          raise RubyCdk::PreconditionError, "Bucket #{bucket} #{reason}, so the operation stops."
        end

        def record(operation, bucket, key, expected_owner)
          @calls << Call.new(operation: operation, args: [ bucket, key ].compact, kwargs: { expected_owner: expected_owner })
        end
      end

      # The output, recorded. What a question is answered is chosen when the
      # fake is built; everything else is kept for the assertions.
      class Output
        include RubyCdk::Deploy::Output

        attr_reader :calls

        # approvals answers ask and confirmations answers confirm: true, false,
        # or an Array consumed in order whose last answer repeats.
        def initialize(approvals: false, confirmations: false)
          @calls = []
          @approvals = answers_of(approvals)
          @confirmations = answers_of(confirmations)
        end

        def target(account:, region:, profile:)
          record(:target, account: account, region: region, profile: profile)
        end

        def changes(list, capabilities: nil)
          record(:changes, list, capabilities: capabilities)
        end

        # The answer is a boolean, as the port promises: exactly true for yes.
        def ask(question)
          record(:ask, question)
          next_answer(@approvals) == true
        end

        # confirmations are the texts that get typed.
        def confirm(text)
          record(:confirm, text)
          next_answer(@confirmations) == text
        end

        def event(event)
          record(:event, event)
        end

        def outputs(hash)
          # Nothing is printed for an empty set of outputs, so nothing is kept.
          record(:outputs, hash) unless hash.nil? || hash.empty?
        end

        def failure(detail)
          record(:failure, detail)
        end

        def retained(list)
          record(:retained, list)
        end

        def announce(text)
          record(:announce, text)
        end

        # The calls of one operation, most recent last.
        def said(operation)
          calls.select { |call| call.operation == operation }
        end

        # Everything that was said, as text: what was printed, asked and announced.
        def transcript
          calls.flat_map { |call| call.args.map(&:to_s) }
        end

        # --- what was said, by kind. The names differ from the port's so that
        # a reader never hides the method the engine calls.

        # { account:, region:, profile: } for each target line.
        def targets
          said(:target).map(&:kwargs)
        end

        # The yes-or-no questions that were asked.
        def questions
          said(:ask).flat_map(&:args)
        end

        # The texts the person was asked to type.
        def confirmations
          said(:confirm).flat_map(&:args)
        end

        # The capabilities shown with each change view.
        def shown_capabilities
          said(:changes).map { |call| call.kwargs[:capabilities] }
        end

        # The list of changes of each change view.
        def shown_changes
          said(:changes).map { |call| call.args.first }
        end

        def shown_events
          said(:event).flat_map(&:args)
        end

        # The outputs of each time they were given.
        def shown_outputs
          said(:outputs).flat_map(&:args)
        end

        def failures
          said(:failure).flat_map(&:args)
        end

        # The resources each destroy said it would keep.
        def shown_retained
          said(:retained).flat_map(&:args).flatten
        end

        def announcements
          said(:announce).flat_map(&:args)
        end

        private

        def record(operation, *args, **kwargs)
          @calls << Call.new(operation: operation, args: args, kwargs: kwargs)
        end

        # A list is taken as it is; anything else is the one answer, repeated.
        def answers_of(answer)
          answer.is_a?(Array) ? answer : [ answer ]
        end

        # The next of the scripted answers; the last one repeats.
        def next_answer(answers)
          answers.length > 1 ? answers.shift : answers.first
        end
      end
    end
  end
end
