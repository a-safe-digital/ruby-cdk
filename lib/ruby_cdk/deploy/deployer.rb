# frozen_string_literal: true

require "json"
require_relative "ports"
require_relative "errors"
require_relative "poller"
require_relative "capabilities"
require_relative "parameters"
require_relative "states"

module RubyCdk
  module Deploy
    # What a deploy or a destroy may do.
    class DeployOptions
      attr_reader :parameters, :tags, :yes, :no_execute, :on_failure, :no_rollback, :outputs_file, :account, :force, :profile

      # force deploys even when the template and the parameters are unchanged.
      # profile is the name of the credential profile; it is shown on the target
      # line and selects nothing here, because the client was built with it.
      def initialize(parameters: {}, tags: {}, yes: false, no_execute: false, on_failure: :delete, no_rollback: false, outputs_file: nil, account: nil,
        force: false, profile: nil)
        @parameters = parameters
        @tags = tags
        @yes = yes
        @no_execute = no_execute
        @on_failure = on_failure
        @no_rollback = no_rollback
        @outputs_file = outputs_file
        @account = account
        @force = force
        @profile = profile
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

    # A resource a destroy will not delete, because its DeletionPolicy keeps it.
    RetainedResource = Struct.new(:logical_id, :resource_type, :deletion_policy, keyword_init: true)

    # Deploys stacks through change sets and destroys them. Talks to AWS only
    # through the two ports.
    #
    # The flow is architecture section 9. It raises for exit codes 1, 3 and 4
    # and returns a DeployResult for everything else: a stack operation that
    # failed or rolled back is a result with outcome :failed and exit code 5,
    # after the resources that failed have been printed.
    class Deployer
      # Change set names are unique per stack, so the one a previous --no-execute
      # left behind is removed before a new one takes its name.
      CHANGE_SET_NAME = "ruby-cdk-deploy-change-set"

      # CloudFormation takes at most this many bytes of template in a request.
      INLINE_TEMPLATE_LIMIT = 51_200

      # OnStackFailure, by the name of the option, in either case.
      ON_FAILURE = { "delete" => "DELETE", "rollback" => "ROLLBACK", "do_nothing" => "DO_NOTHING" }.freeze

      # A change set in one of these is still being created.
      CREATING_STATUSES = %w[CREATE_PENDING CREATE_IN_PROGRESS].freeze

      # The reasons CloudFormation gives when a change set has nothing to do:
      # the two the CDK reads, and the code of its early validation.
      NO_CHANGE_REASONS = [
        "The submitted information didn't contain changes.",
        "No updates are to be performed.",
        "NoChangesInUpdateSet"
      ].freeze

      # Right after an execution DescribeStacks can still answer the status
      # from before it. The CDK gives that read three chances to catch up.
      STALE_REVIEW_READS = 3

      # A creation that failed and rolled back this far. The next deploy deletes the stack first.
      FAILED_CREATION_STATUSES = %w[ROLLBACK_COMPLETE ROLLBACK_FAILED].freeze

      # The statuses in which an operation SUCCEEDED. It is not the same
      # question as whether the stack is stable: UPDATE_ROLLBACK_COMPLETE is a
      # stable stack, one that can be updated again, and it is how an update
      # that failed ends. This is the CDK's isDeploySuccess.
      DEPLOYED_STATUSES = %w[CREATE_COMPLETE UPDATE_COMPLETE IMPORT_COMPLETE].freeze

      # The stack itself, in its own events.
      STACK_TYPE = "AWS::CloudFormation::Stack"

      # The DeletionPolicy values under which a deleted stack leaves a resource behind.
      RETAINING_POLICIES = %w[Retain RetainExceptOnCreate Snapshot].freeze

      # poller waits for a change set to be created; operation_poller follows a
      # stack operation. Both take a Poller, so a test never waits.
      def initialize(client:, store:, output:, poller: Poller.change_set, operation_poller: Poller.operation)
        @client = client
        @store = store
        @output = output
        @poller = poller
        @operation_poller = operation_poller
        @events_unavailable = false
      end

      # stack is the stack: anything that answers stack_name, env,
      # termination_protection and tags. template is the template as JSON text.
      # identity is who the credentials are for, from the client.
      def deploy(stack:, template:, identity:, options:)
        name = stack.stack_name
        check_account(name, stack, identity, options)

        body = parse_template(template)
        ensure_template_fits(template)
        on_failure = on_failure_code(options.on_failure)
        parameters = Parameters.new(body, options.parameters)
        capabilities = Capabilities.for(body)
        tags = tags_of(stack.tags, options.tags)

        show_target(identity, options)

        state, info = prepare_stack(name, client.stack_state(name))
        if state == :stable && unchanged?(name, info, body, parameters, tags, options)
          reconcile_protection(info.id || name, info.termination_protection, stack.termination_protection)
          deliver_outputs(info, options)
          return DeployResult.new(stack_name: name, stack_id: info.id, outcome: :no_changes, outputs: outputs_of(info))
        end

        creating = %i[absent review].include?(state)
        output.announce("#{name}: #{creating ? "creating" : "updating"}: preparing a CloudFormation change set...")
        client.delete_change_set(name, CHANGE_SET_NAME) unless state == :absent

        change_set = change_set_with_rejection(name, nil, creating) do
          client.create_change_set(name, CHANGE_SET_NAME, template: template, change_set_type: creating ? :create : :update,
            parameters: parameters.api, tags: tags, capabilities: capabilities, on_stack_failure: creating ? on_failure : nil)
        end
        change_set = wait_for_change_set(name, change_set.id)

        # The stack exists from here on, with an ID of its own. Later calls use
        # the ID, which still names the stack when it has been deleted.
        current = info || client.stack_info(name)
        target = current&.id || name
        wanted_protection = !!stack.termination_protection

        if no_changes?(change_set)
          client.delete_change_set(name, change_set.id)
          output.announce("#{name}: no changes to deploy. CloudFormation reports that the change set is empty." +
            (options.force ? " --force was given, but the template and the parameters lead to no change." : ""))
          reconcile_protection(target, current&.termination_protection, wanted_protection)
          deliver_outputs(current, options)
          return DeployResult.new(stack_name: name, stack_id: current&.id, outcome: :no_changes, outputs: outputs_of(current))
        end

        changes = changes_of(change_set)

        unless executable?(change_set)
          detail = rejection_detail(name, change_set)
          output.failure(detail)
          raise ChangeSetFailed, "#{detail}#{discard(name, change_set.id, creating, false)}"
        end

        output.changes(changes, capabilities: capabilities)
        reconcile_protection(target, current&.termination_protection, wanted_protection)

        if options.no_execute
          output.announce("#{name}: the change set #{change_set.id} was created and left unexecuted (--no-execute). " \
            "Execute it in the CloudFormation console, or run the command again without --no-execute.")
          return DeployResult.new(stack_name: name, stack_id: current&.id, outcome: :not_executed, changes: changes,
            outputs: outputs_of(current))
        end

        unless approved?(options, "Deploy these changes to stack #{name} in account #{identity.account} (#{identity.region})?")
          raise ApprovalRequired, "Approval for the changes to stack #{name} was not given, so nothing was deployed. " \
            "The change set was deleted#{creating ? ", with the new stack" : ""}." \
            "#{discard(name, change_set.id, creating, creating && wanted_protection)}" \
            "\nRun the command again in a terminal to approve it, or with --yes to deploy without asking."
        end

        change_set_with_rejection(name, change_set.id, creating, was_protected: creating && wanted_protection) do
          # A creation carries OnStackFailure instead, and the two cannot go together.
          client.execute_change_set(target, change_set.id, disable_rollback: !creating && options.no_rollback,
            retain_except_on_create: true)
        end

        final_state, final_info, events = follow_operation(target, name)
        if final_state == :stable && final_info && DEPLOYED_STATUSES.include?(final_info.status)
          deliver_outputs(final_info, options)
          return DeployResult.new(stack_name: name, stack_id: final_info.id, outcome: :deployed, changes: changes,
            outputs: outputs_of(final_info))
        end

        output.failure(operation_failure(name, final_state, final_info, events, :deploy))
        DeployResult.new(stack_name: name, stack_id: final_info&.id, outcome: :failed, changes: changes, exit_code: 5)
      end

      def destroy(stack_name:, identity:, options:)
        check_identity(identity, options)
        show_target(identity, options)

        state = client.stack_state(stack_name)
        info = state == :absent ? nil : client.stack_info(stack_name)
        if info.nil?
          output.announce("Stack #{stack_name} does not exist: nothing to destroy.")
          return DeployResult.new(stack_name: stack_name, outcome: :no_changes)
        end
        raise StackBusy, busy_message(stack_name, info.status) if state == :busy

        if info.termination_protection
          raise DestroyRefused, "Stack #{stack_name} has termination protection, so destroy refuses to delete it. Nothing was deleted.\n" \
            "Turn it off first (set termination_protection: false on the stack and deploy, or in the CloudFormation console: " \
            "Stack actions, then Edit termination protection), then run `ruby-cdk destroy #{stack_name}` again."
        end

        target = info.id || stack_name
        output.retained(retained_resources(stack_name, client.get_template(target)))
        unless options.yes == true || output.confirm(stack_name) == true
          raise ApprovalRequired, "The name of stack #{stack_name} was not typed, so nothing was deleted.\n" \
            "Run the command again and type the stack name when asked, or with --yes to destroy without asking."
        end

        client.delete_stack(target)
        final_state, final_info, events = follow_operation(target, stack_name)
        if final_state == :absent
          return DeployResult.new(stack_name: stack_name, stack_id: info.id, outcome: :deployed)
        end

        output.failure(operation_failure(stack_name, final_state, final_info || info, events, :destroy))
        DeployResult.new(stack_name: stack_name, stack_id: final_info&.id || info.id, outcome: :failed, exit_code: 5)
      end

      private

      attr_reader :client, :store, :output, :poller, :operation_poller

      # --- section 13: who the credentials are for, and where the stack may go

      # Nothing here falls back: every mismatch is refused before any request.
      def check_account(name, stack, identity, options)
        check_identity(identity, options)

        env = stack.env
        if concrete?(env)
          if identity.account.to_s != env.account.to_s
            raise TargetMismatch, "The credentials are for account #{identity.account}, but stack #{name} has env " \
              "#{env.account}/#{env.region}. A stack with an env deploys only there. Nothing was deployed.\n" \
              "Run the command again with a profile of account #{env.account} (--profile NAME), or change the stack's env."
          end
          if identity.region.to_s != env.region.to_s
            raise TargetMismatch, "The client is for region #{identity.region}, but stack #{name} has env " \
              "#{env.account}/#{env.region}. A stack with an env deploys only there. Nothing was deployed.\n" \
              "Run the command again with --region #{env.region}, or change the stack's env."
          end
          return
        end

        return unless options.yes && options.account.nil?

        raise AccountRequired, "An unattended deploy (--yes) of stack #{name}, which has no env, needs --account: " \
          "nobody is there to see the target. The credentials are for account #{identity.account} in #{identity.region}.\n" \
          "Run the command again with --account #{identity.account} if that is the account you mean, or give the stack an env."
      end

      def check_identity(identity, options)
        if identity.nil? || identity.account.to_s.empty?
          raise AccountUnresolved, "No account could be resolved from the credentials, so there is no target to deploy to. Nothing was changed.\n" \
            "Check the profile and the credentials (--profile NAME), then run the command again."
        end

        return if options.account.nil? || options.account.to_s == identity.account.to_s

        raise AccountMismatch, "--account #{options.account} was given, but the credentials are for account #{identity.account}. Nothing was changed.\n" \
          "Run the command again without --account, or with --account #{identity.account} if that is the account you mean " \
          "and the credentials are the ones that are wrong (--profile NAME)."
      end

      # An env with both an account and a region.
      def concrete?(env)
        !env.nil? && env.respond_to?(:account) && env.respond_to?(:region) && !env.account.to_s.empty? && !env.region.to_s.empty?
      end

      def show_target(identity, options)
        output.target(account: identity.account, region: identity.region, profile: options.profile)
      end

      # --- the template, before any request

      def parse_template(template)
        body = JSON.parse(template)
        raise InvalidTemplate, "The template is not a JSON object, so it cannot be deployed." unless body.is_a?(Hash)

        body
      rescue JSON::ParserError, TypeError
        raise InvalidTemplate, "The template is not valid JSON, so CloudFormation cannot take it. Synthesize the stack again."
      end

      def ensure_template_fits(template)
        return if template.bytesize <= INLINE_TEMPLATE_LIMIT

        raise TemplateTooLarge, "The template is #{template.bytesize} bytes, and CloudFormation takes at most " \
          "#{INLINE_TEMPLATE_LIMIT} bytes in a request. Nothing was deployed.\n" \
          "Upload the template through the asset bucket, which a later wave does by itself, or deploy a smaller template."
      end

      def on_failure_code(value)
        ON_FAILURE[value.to_s.downcase] ||
          raise(RubyCdk::UsageError, "--on-failure must be one of DELETE, ROLLBACK or DO_NOTHING, not #{value.inspect}.")
      end

      # --- the stack's state

      # Refuses the states nothing can be done in, removes a failed creation,
      # and answers [state, stack info] with info nil when the stack is absent.
      def prepare_stack(name, state)
        info = state == :absent ? nil : client.stack_info(name)
        return [ :absent, nil ] unless info

        case state
        when :busy
          raise StackBusy, busy_message(name, info.status)
        when :rollback_failed
          raise StackNeedsRepair, "Stack #{name} is in #{info.status} and has to be repaired before it can be deployed again. " \
            "Nothing was changed. #{States.repair_path(info.status)}"
        when :rollback_complete
          output.announce("#{name}: the stack is in #{info.status}, so its first deploy failed and rolled back. " \
            "Deleting it, then creating it again.")
          client.delete_stack(info.id || name)
          final = wait_settled(info.id || name, "its deletion")
          return [ :absent, nil ] if final == :absent

          status = client.stack_info(info.id || name)&.status
          raise StackNeedsRepair, "Stack #{name} could not be deleted: it is in #{status || final}. Nothing was deployed. " \
            "#{States.repair_path(status)}"
        end

        [ state, info ]
      end

      def busy_message(name, status)
        "Stack #{name} is #{status || "busy"}: an operation is already running on it, and two at once is not possible. " \
          "Nothing was changed.\nWait for it to finish (the CloudFormation console shows it), then run the command again."
      end

      # Sleeps until the stack is no longer busy. Answers the state it settled in.
      def wait_settled(target, what)
        polling(operation_poller, "the stack did not finish #{what}") do
          state = client.stack_state(target)
          state unless state == :busy
        end
      end

      # --- section 9: unchanged means skipped

      # Only a template that parses as JSON, and parameters and tags that match,
      # prove that nothing changed. Anything else deploys, and the change set says so.
      #
      # YAML is not read, on purpose. This engine always sends JSON, so a stack
      # holds a YAML template only when another tool deployed it. How
      # CloudFormation types a YAML value is not something to guess at, and it
      # is the Wave 2 port of the cloudformation-include yaml cases that reads
      # it. Until then such a stack is not skipped: its change set is created,
      # CloudFormation answers that there is nothing to do, and the deploy ends
      # with exit 0 one request later.
      def unchanged?(name, info, body, parameters, tags, options)
        return false if options.force || options.no_execute || parameters.resolved_by_cloud_formation?

        deployed = JSON.parse(client.get_template(info.id || name).to_s)
        return false unless deployed == body
        return false if parameters.changes?(client.stack_parameters(info.id || name))

        tag_pairs(client.stack_tags(info.id || name)) == tag_pairs(tags)
      rescue JSON::ParserError, TypeError
        false
      end

      # --- change sets

      # CloudFormation can refuse a change set when the request is made, or when
      # it is executed. The adapter raises RubyCdk::ChangeSetRejected then; the
      # engine cleans up after a creation and reports it with everything else
      # it rejects. was_protected says whether the new stack was protected.
      def change_set_with_rejection(name, change_set_id, creating, was_protected: false)
        yield
      rescue RubyCdk::ChangeSetRejected => e
        raise ChangeSetFailed, "#{e.message}#{discard(name, change_set_id, creating, was_protected)}"
      end

      def wait_for_change_set(name, change_set_id)
        polling(poller, "CloudFormation did not finish creating the change set for stack #{name}") do
          described = client.describe_change_set(name, change_set_id)
          described unless CREATING_STATUSES.include?(described.status)
        end
      end

      def no_changes?(change_set)
        if change_set.status == "CREATE_COMPLETE"
          return changes_of(change_set).empty?
        end

        reason = change_set.status_reason.to_s
        change_set.status == "FAILED" && NO_CHANGE_REASONS.any? { |known| reason.include?(known) }
      end

      def executable?(change_set)
        change_set.status == "CREATE_COMPLETE" && [ nil, "AVAILABLE" ].include?(change_set.execution_status)
      end

      def changes_of(change_set)
        change_set.changes || []
      end

      def rejection_detail(name, change_set)
        head = if change_set.status == "FAILED"
          "CloudFormation rejected the change set for stack #{name}: #{change_set.status_reason}"
        else
          "The change set for stack #{name} cannot be executed (#{change_set.status}, " \
            "#{change_set.execution_status || "no execution status"}): #{change_set.status_reason}"
        end
        lines = [ head ]
        operation_events(name, change_set.id).each do |event|
          lines << "  #{event.logical_id} (#{event.resource_type}) #{event.resource_status}: #{event.status_reason}"
        end
        lines << "Correct the cause and run `ruby-cdk deploy #{name}` again."
        lines.join("\n")
      end

      # The early validation events, when the client can read them. When it
      # cannot, the answer is empty and the reason is still reported.
      def operation_events(name, change_set_id)
        return [] unless client.respond_to?(:operation_events)

        Array(client.operation_events(name, change_set_id))
      rescue NotImplementedError, StandardError
        []
      end

      # Housekeeping. A change set that is not going to be executed is deleted,
      # and so is the stack a creation made. was_protected says whether that
      # stack was protected from deletion, which then has to be lifted first.
      # Answers a note when the cleanup did not finish, and nil when it did.
      def discard(name, change_set_id, creating, was_protected)
        client.delete_change_set(name, change_set_id) if change_set_id
        if creating && client.stack_state(name) == :review
          client.update_termination_protection(name, enabled: false) if was_protected
          client.delete_stack(name)
          wait_settled(name, "its deletion")
        end
        nil
      rescue StandardError => e
        "\nThe cleanup after that did not finish (#{e.message}). Look at stack #{name} in the CloudFormation console " \
          "and remove what is left of it before deploying it again."
      end

      def reconcile_protection(target, current, wanted)
        wanted = !!wanted
        return if !!current == wanted

        client.update_termination_protection(target, enabled: wanted)
      end

      # Whether a deploy may go ahead without a person: --yes, or a yes to the
      # question. Both have to be exactly true: anything else an output answers
      # is not an approval, and an approval given by accident is the worst thing
      # this engine can do.
      def approved?(options, question)
        options.yes == true || output.ask(question) == true
      end

      # --- an operation in progress

      # Follows the operation from its start to a terminal status, printing
      # every event as it arrives. Answers [state, stack info, events]; the
      # info is nil when the stack is gone.
      def follow_operation(target, name)
        seen = {}
        events = []
        stale_reviews = 0
        @events_unavailable = false
        @newest_event = nil

        state = polling(operation_poller, "the operation on stack #{name} did not finish") do
          read_events(target, seen, events, name)
          current = client.stack_state(target)
          case current
          when :busy
            stale_reviews = 0
            nil
          when :review
            # Right after an execution the status from before it can still be read.
            stale_reviews += 1
            stale_reviews <= STALE_REVIEW_READS ? nil : current
          else
            current
          end
        end
        read_events(target, seen, events, name)

        # A stack that is no longer there to be described is gone.
        info = client.stack_info(target) unless state == :absent
        [ info ? state : :absent, info, events ]
      end

      # Prints the events that have not been read yet. The first read leaves the
      # moment to the client; the next ones ask for what is newer than the last
      # event read, which is kept between the reads of one operation.
      def read_events(target, seen, events, name)
        return if @events_unavailable

        client.events(target, after: @newest_event).sort_by { |event| event.timestamp || Time.at(0) }.each do |event|
          next if seen[event]

          seen[event] = true
          events << event
          output.event(event)
          timestamp = event.timestamp
          @newest_event = timestamp if timestamp && (@newest_event.nil? || timestamp > @newest_event)
        end
      rescue StandardError => e
        @events_unavailable = true
        output.announce("The events of stack #{name} could not be read (#{e.message}), so they are not shown. " \
          "The stack's status is still followed.")
      end

      # Why an operation this engine started did not end well, with the
      # resources that failed and the command to run next. purpose is :deploy
      # or :destroy.
      def operation_failure(name, state, info, events, purpose)
        lines = [ failure_head(name, state, info&.status, purpose) ]
        failed = failed_resources(events)
        if failed.any?
          lines << "Resources that failed:"
          failed.each { |logical_id, (resource_type, resource_status, reason)| lines << "  #{logical_id} (#{resource_type}) #{resource_status}: #{reason}" }
        else
          lines << "No resource reported a failure in the events that were read. Read the stack's events in the CloudFormation console."
        end
        lines.join("\n")
      end

      # The first lines of a failure: what happened and what to do next.
      def failure_head(name, state, status, purpose)
        if purpose == :destroy
          if state == :review
            return "Stack #{name} is still in REVIEW_IN_PROGRESS: the deletion did not start.\n" \
              "Look at the stack in the CloudFormation console, then run the command again."
          end

          way_out = States.repair_path(status) ||
            "Look at the stack in the CloudFormation console, fix what blocks the deletion, and run `ruby-cdk destroy #{name}` again."
          return "Stack #{name} could not be deleted: it ended in #{status}.\n#{way_out}"
        end

        case state
        when :absent
          "Stack #{name} is gone: its creation failed, and CloudFormation deleted it as its change set asked.\n" \
            "Fix the cause and run `ruby-cdk deploy #{name}` again."
        when :review
          "Stack #{name} is still in REVIEW_IN_PROGRESS: the execution of its change set did not start.\n" \
            "Look at the stack in the CloudFormation console, then run the command again."
        else
          failed_status(name, status)
        end
      end

      # For a deploy that ended in a status that is not a stable one.
      def failed_status(name, status)
        head, next_step =
          if (repair = States.repair_path(status))
            [ "Stack #{name} ended in #{status}, and has to be repaired before it can be deployed again.", repair ]
          elsif FAILED_CREATION_STATUSES.include?(status)
            [ "Stack #{name} ended in #{status}: its creation failed and was rolled back.",
              "Fix the cause and run `ruby-cdk deploy #{name}` again: the failed stack is deleted and created again." ]
          else
            [ "Stack #{name} ended in #{status}: the operation was rolled back.", "Fix the cause and run `ruby-cdk deploy #{name}` again." ]
          end
        "#{head}\n#{next_step}"
      end

      # { logical id => [ resource type, status, reason ] }, from the last
      # failure of each resource. The stack's own events are left out: they
      # summarise the resources.
      def failed_resources(events)
        events.select { |event| event.resource_status.to_s.end_with?("_FAILED") && event.resource_type != STACK_TYPE }
          .group_by(&:logical_id)
          .transform_values { |list| last = list.last; [ last.resource_type, last.resource_status, last.status_reason ] }
      end

      def polling(waiter, description)
        waiter.run { yield }
      rescue WaitTimedOut
        raise WaitTimedOut, "Stopped waiting: #{description} within the limit of #{waiter.limit} seconds. " \
          "Nothing was changed by stopping; the operation goes on in AWS.\n" \
          "Look at the stack in the CloudFormation console and run the command again once it has finished."
      end

      # --- outputs

      def outputs_of(info)
        info&.outputs || {}
      end

      def deliver_outputs(info, options)
        outputs = outputs_of(info)
        output.outputs(outputs)
        return unless options.outputs_file

        File.write(options.outputs_file, "#{JSON.pretty_generate(outputs)}\n")
      end

      # --- tags

      # The stack's own tags, with the command's on top of them.
      def tags_of(*sources)
        merged = {}
        sources.each do |source|
          entries_of(source).each { |key, value| merged[key.to_s] = value.to_s }
        end
        merged.map { |key, value| { key: key, value: value } }
      end

      def tag_pairs(tags)
        entries_of(tags).map { |key, value| [ key.to_s, value.to_s ] }.sort
      end

      # [key, value] pairs from a Hash, from { key:, value: } hashes, or from pairs.
      def entries_of(tags)
        case tags
        when Hash then tags.to_a
        when Array
          tags.map do |tag|
            if tag.is_a?(Hash)
              [ tag[:key] || tag["key"], tag[:value] || tag["value"] ]
            else
              Array(tag)
            end
          end
        else []
        end
      end

      # --- destroy

      # The resources the stack's template keeps when the stack is deleted.
      def retained_resources(name, template_text)
        body = JSON.parse(template_text.to_s)
        resources = body.is_a?(Hash) && body["Resources"].is_a?(Hash) ? body["Resources"] : {}
        resources.filter_map do |logical_id, resource|
          policy = resource.is_a?(Hash) ? resource["DeletionPolicy"] : nil
          next unless RETAINING_POLICIES.include?(policy)

          RetainedResource.new(logical_id: logical_id, resource_type: resource["Type"], deletion_policy: policy)
        end.sort_by(&:logical_id)
      rescue JSON::ParserError, TypeError
        output.announce("The deployed template of stack #{name} is not JSON this tool can read, so the resources it retains " \
          "could not be listed. Read its DeletionPolicy values in the CloudFormation console before confirming.")
        []
      end
    end
  end
end
