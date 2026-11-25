# frozen_string_literal: true

require "aws-sdk-cloudformation"
require "aws-sdk-s3"
require_relative "../errors"
require_relative "ports"

module RubyCdk
  module Deploy
    # The AWS SDK behind the two ports. This is the only file in the gem that
    # knows an Aws:: client exists: a command loads it on its own, and `synth`
    # never does.
    #
    # It knows the ports and the error classes, and nothing of the engine. What
    # it raises is what a component that did not raise it can recognise: the
    # classes in errors.rb. The engine rescues those.
    module Sdk
      # The two clients a command needs: cfn answers CfnClient, store answers ObjectStore.
      Clients = Data.define(:cfn, :store)

      # Exit 1. AWS refused a request, or could not be reached. code is the
      # error code AWS answered with, or nil when there was no answer.
      class RequestFailed < RubyCdk::PreconditionError
        attr_reader :code

        def initialize(message, code: nil)
          @code = code
          super(message)
        end
      end

      # Exit 3. CloudFormation refused the change set when it was asked for,
      # before there was a change set to describe.
      class ChangeSetRequestRejected < RubyCdk::ChangeSetRejected
        attr_reader :code

        def initialize(message, code: nil)
          @code = code
          super(message)
        end
      end

      # The region, as the SDK's own search order would find it after the two
      # steps taken over here. regional_endpoint.rb, in aws-sdk-core 3.271.1.
      REGION_VARIABLES = %w[AWS_REGION AMAZON_REGION AWS_DEFAULT_REGION].freeze

      # What the SDK raises when it cannot find or use credentials, which is
      # not AWS answering.
      CREDENTIAL_FAILURES = [
        Aws::Errors::NoSuchProfileError,
        Aws::Errors::MissingCredentialsError,
        Aws::Errors::NoSourceProfileError,
        Aws::Errors::NoSourceCredentialsError,
        Aws::Errors::CredentialSourceConflictError,
        Aws::Errors::InvalidCredentialSourceError,
        Aws::Errors::SourceProfileCircularReferenceError,
        Aws::Errors::InvalidSSOCredentials,
        Aws::Errors::InvalidSSOToken,
        Aws::Errors::InvalidLoginToken
      ].freeze

      module_function

      # The region a command uses. It is always found here and passed to every
      # client, so that the SDK's own search order never picks one (architecture
      # section 13):
      #
      # 1. the region given: --region, else the stack's env.region;
      # 2. AWS_REGION, then AMAZON_REGION, then AWS_DEFAULT_REGION, which is the
      #    SDK's own list in its own order;
      # 3. the region the profile names in the shared config file
      #    (AWS_CONFIG_FILE, or ~/.aws/config).
      #
      # When nothing names one, the command refuses.
      def resolve_region(profile:, region:)
        # A region that is blank is not one.
        found = region.to_s.strip.empty? ? nil : region
        found = named_in_environment if found.to_s.empty?
        found = profile_region(profile) if found.to_s.empty?
        if found.to_s.empty?
          whose = profile ? "the profile #{profile}" : "the default profile"
          Kernel.raise RubyCdk::PreconditionError, "No region to deploy to: none was given, none is in #{REGION_VARIABLES.join(", ")}, " \
            "and #{whose} names none in the shared config file. Nothing was changed.\n" \
            "Run the command again with --region NAME."
        end

        check_region(found)
        found
      end

      # The first of the SDK's environment variables that names a region.
      def named_in_environment
        REGION_VARIABLES.filter_map { |name| value = ENV[name]; value unless value.to_s.empty? }.first
      end

      # The two clients a command needs, for one profile and one region.
      #
      # credentials and stub_responses are for tests, and for tools that only
      # need a client object: the default credential chain searches for
      # credentials and, finding none, waits on the EC2 metadata endpoint
      # (D-024). Nothing outside a test passes them.
      def clients(profile:, region:, credentials: nil, stub_responses: false)
        region = resolve_region(profile: profile, region: region)
        options = { credentials: credentials, stub_responses: stub_responses }
        Clients.new(
          cfn: cfn_client(region: region, profile: profile, **options),
          store: object_store(region: region, profile: profile, **options)
        )
      end

      # The CloudFormation port.
      def cfn_client(region:, profile: nil, credentials: nil, stub_responses: false)
        CloudFormationClient.new(region: region, profile: profile, credentials: credentials, stub_responses: stub_responses)
      end

      # The object store port.
      def object_store(region:, profile: nil, credentials: nil, stub_responses: false)
        ObjectStoreClient.new(region: region, profile: profile, credentials: credentials, stub_responses: stub_responses)
      end

      # The options every client is built with. region is always among them.
      # profile narrows the standard credential chain to that profile; without
      # one, the chain is the SDK's own.
      def options_for(region:, profile: nil, credentials: nil, stub_responses: false)
        options = { region: region }
        options[:profile] = profile if profile
        options[:credentials] = credentials if credentials
        options[:stub_responses] = true if stub_responses
        options
      end

      # Runs a request. When it fails, what is raised is one of this gem's
      # errors, or the error itself when it is not one the SDK documents.
      # rejects decides whether the refusal of a change set is told apart.
      def request(rejects: false)
        yield
      rescue StandardError => e
        translated = failure_of(e, rejects: rejects)
        Kernel.raise translated if translated

        Kernel.raise
      end

      # The error of this gem that stands for one of the SDK's, or nil.
      def failure_of(error, rejects: false)
        case error
        when Aws::Errors::ServiceError
          code = error.code || error.class.name.to_s.split("::").last
          message = "#{code}: #{error.message}"
          return ChangeSetRequestRejected.new(message, code: code) if rejects && CloudFormationClient::REJECTED_CODES.include?(code)

          RequestFailed.new(message, code: code)
        when Seahorse::Client::NetworkingError
          RequestFailed.new("AWS could not be reached (#{error.message}).")
        when *CREDENTIAL_FAILURES
          kind = error.class.name.to_s.split("::").last
          RequestFailed.new("The credentials could not be found or used (#{kind}: #{error.message}).")
        end
      end

      # The region the profile names in the shared config file.
      #
      # Two things about SharedConfig are easy to get wrong, and both were:
      #
      # - The profile is an option of `region`, not of `new`. The constructor
      #   takes `profile_name`, and ignores `profile:`: SharedConfig.new(profile: "x")
      #   is the default profile.
      # - The config file is read only with `config_enabled: true`. Without it,
      #   `region` answers nil for every profile.
      #
      # Together they make the wrong call answer the default profile's region
      # for a named profile: the wrong region, in silence. This is the call the
      # SDK makes itself (plugins/regional_endpoint.rb).
      #
      # AWS_SDK_CONFIG_OPT_OUT is honoured as the SDK honours it (aws-sdk-core.rb):
      # a file the user told the SDK to ignore is not read for a region either.
      def profile_region(profile)
        return nil if ENV["AWS_SDK_CONFIG_OPT_OUT"]

        Aws::SharedConfig.new(config_enabled: true).region(profile: profile)
      rescue StandardError => e
        Kernel.raise RubyCdk::PreconditionError, "The shared config file could not be read for a region (#{e.message}).\n" \
          "Run the command again with --region NAME."
      end

      # A region is checked against the partitions the SDK ships, so that a
      # typo is refused here and not by a request to an endpoint that does not
      # exist. The cost: a region newer than the pinned aws-partitions is
      # refused until the gem is updated, which is the safe side of the trade.
      def check_region(region)
        known = Aws::Partitions.partitions.any? { |partition| partition.region?(region) }
        return if known

        Kernel.raise RubyCdk::PreconditionError, "#{region.inspect} is not a region the AWS SDK knows, so nothing was changed.\n" \
          "Run the command again with --region NAME, for example eu-west-1."
      end

      # The CloudFormation port.
      class CloudFormationClient
        include CfnClient

        # The events of an operation are read from this many seconds before the
        # engine asks: this machine's clock and the one at AWS are never the same.
        EVENT_SKEW = 5

        # The error codes CloudFormation answers with when it refuses a change
        # set, as opposed to when something else went wrong.
        REJECTED_CODES = %w[
          ValidationError
          InsufficientCapabilitiesException
          AlreadyExistsException
          CreatedButModifiedException
          InvalidChangeSetStatusException
        ].freeze

        # How CloudFormation says that there is no such stack.
        MISSING_STACK = /does not exist/i

        attr_reader :raw

        def initialize(region:, profile: nil, credentials: nil, stub_responses: false)
          @profile = profile
          @credentials = credentials
          @stub_responses = stub_responses
          @raw = Aws::CloudFormation::Client.new(**client_options(region))
        rescue ArgumentError
          raise RequestFailed, "The AWS SDK does not accept the region #{region.inspect}. Run the command again with --region NAME."
        end

        # The STS client, built on first use with the options the main client
        # was built with, so that a test stubs it the same way.
        def sts
          @sts ||= Aws::STS::Client.new(**client_options(@raw.config.region))
        end

        # Who the credentials are for, asked of STS with the same region and
        # the same profile as the client. The account is an identifier; it is
        # returned whole, and nothing here prints anything.
        #
        # The STS client is built on the first call, with the options the main
        # client was built with, so a test stubs it the same way.
        def resolve_identity
          response = Sdk.request { sts.get_caller_identity }
          Identity.new(account: response.account, region: @raw.config.region, arn: response.arn)
        rescue RequestFailed => e
          raise RubyCdk::PreconditionError, "No account could be resolved from the credentials, so there is no target to deploy to. " \
            "#{e.message}\nNothing was changed. Check the profile and the region (--profile NAME, --region NAME), then run the command again."
        end

        def stack_state(name)
          stack = stack_of(name)
          state = StackStatus.state(stack&.stack_status)
          if state.nil?
            raise RubyCdk::PreconditionError, "CloudFormation answers the stack status #{stack.stack_status.inspect}, " \
              "which this tool does not know how to place. Nothing was changed. Report it as a bug in ruby-cdk."
          end

          state
        end

        def stack_info(name)
          stack = stack_of(name)
          return nil unless stack

          StackInfo.new(
            name: stack.stack_name,
            id: stack.stack_id,
            status: stack.stack_status,
            outputs: (stack.outputs || []).to_h { |output| [ output.output_key, output.output_value ] },
            termination_protection: !!stack.enable_termination_protection
          )
        end

        def stack_parameters(name)
          (stack_of(name)&.parameters || []).to_h { |parameter| [ parameter.parameter_key, parameter.parameter_value ] }
        end

        def stack_tags(name)
          (stack_of(name)&.tags || []).map { |tag| { key: tag.key, value: tag.value } }
        end

        # Every page, and every stack that is not deleted.
        def list_stacks
          stacks = []
          response = Sdk.request { @raw.list_stacks }
          loop do
            response.stack_summaries.each do |summary|
              next if summary.stack_status == StackStatus::DELETED

              stacks << ListedStack.new(name: summary.stack_name, id: summary.stack_id, status: summary.stack_status)
            end
            break unless response.next_token

            response = Sdk.request { @raw.list_stacks(next_token: response.next_token) }
          end
          stacks
        end

        # Answers the change set's ID. A template above the inline limit goes to
        # the bucket, and the request carries its URL instead of its body: the
        # two never go together, as the port promises.
        def create_change_set(name, change_set_name, template:, change_set_type:, parameters:, tags:, capabilities:,
          on_stack_failure: nil, template_url: nil)
          params = {
            stack_name: name,
            change_set_name: change_set_name,
            change_set_type: change_set_type.to_s.upcase,
            parameters: parameter_pairs(parameters),
            tags: pairs(tags, :key, :value),
            capabilities: capabilities
          }
          params[:template_body] = template if template
          params[:template_url] = template_url if template_url
          params[:on_stack_failure] = on_stack_failure.to_s.upcase if on_stack_failure
          response = Sdk.request(rejects: true) { @raw.create_change_set(params) }
          ChangeSet.new(id: response.id || change_set_name)
        end

        # Every page of the changes, so that the list is never truncated.
        def describe_change_set(name, change_set_id)
          head = Sdk.request { @raw.describe_change_set(stack_name: name, change_set_name: change_set_id) }
          response = head
          changes = head.changes || []
          while response.next_token
            response = Sdk.request do
              @raw.describe_change_set(stack_name: name, change_set_name: change_set_id, next_token: response.next_token)
            end
            changes.concat(response.changes || [])
          end

          ChangeSet.new(
            id: head.change_set_id || change_set_id,
            status: head.status,
            status_reason: head.status_reason,
            execution_status: head.execution_status,
            changes: changes.map do |entry|
              resource = entry.resource_change
              Change.new(
                action: resource.action,
                logical_id: resource.logical_resource_id,
                resource_type: resource.resource_type,
                replacement: resource.replacement,
                detail: plain(resource.details)
              )
            end
          )
        end

        # DisableRollback is sent only when it is true: a creation carries
        # OnStackFailure instead, and CloudFormation takes the two together for
        # an error. So is RetainExceptOnCreate, which is what the engine always asks.
        def execute_change_set(name, change_set_id, disable_rollback: false, retain_except_on_create: true)
          params = { stack_name: name, change_set_name: change_set_id }
          params[:disable_rollback] = true if disable_rollback
          params[:retain_except_on_create] = true if retain_except_on_create
          Sdk.request(rejects: true) { @raw.execute_change_set(params) }
          nil
        end

        def delete_change_set(name, change_set_id)
          Sdk.request { @raw.delete_change_set(stack_name: name, change_set_name: change_set_id) }
          nil
        end

        def delete_stack(name)
          Sdk.request { @raw.delete_stack(stack_name: name) }
          nil
        end

        def list_resources(name_or_id)
          resources = []
          response = Sdk.request { @raw.list_stack_resources(stack_name: name_or_id) }
          loop do
            resources.concat(response.stack_resource_summaries || [])
            break unless response.next_token

            response = Sdk.request { @raw.list_stack_resources(stack_name: name_or_id, next_token: response.next_token) }
          end
          resources.map do |summary|
            StackResource.new(logical_id: summary.logical_resource_id, status: summary.resource_status, physical_id: summary.physical_resource_id)
          end
        end

        # The events after a moment, oldest first. DescribeStackEvents answers
        # newest first, so paging stops at the first page that reaches back to
        # the moment: a long-lived stack does not have its whole history read.
        def events(name_or_id, after:)
          after ||= Time.now - EVENT_SKEW
          found = []
          response = Sdk.request { @raw.describe_stack_events(stack_name: name_or_id) }
          loop do
            page = response.stack_events || []
            found.concat(page)
            break unless response.next_token && page.any? && page.all? { |event| event.timestamp && event.timestamp > after }

            response = Sdk.request { @raw.describe_stack_events(stack_name: name_or_id, next_token: response.next_token) }
          end
          found.select { |event| event.timestamp && event.timestamp > after }
            .sort_by(&:timestamp)
            .map do |event|
              Event.new(
                resource_status: event.resource_status,
                logical_id: event.logical_resource_id,
                resource_type: event.resource_type,
                status_reason: event.resource_status_reason,
                timestamp: event.timestamp
              )
            end
        rescue RequestFailed => e
          raise unless missing?(e)

          []
        end

        def get_template(name)
          Sdk.request { @raw.get_template(stack_name: name) }.template_body
        rescue RequestFailed => e
          raise unless missing?(e)

          nil
        end

        def update_termination_protection(name, enabled:)
          Sdk.request { @raw.update_termination_protection(stack_name: name, enable_termination_protection: enabled) }
          nil
        end

        # The events of a change set that failed its validation (DescribeEvents,
        # newer than DescribeStackEvents). Only the failed ones are asked for.
        def operation_events(name, change_set_id)
          response = Sdk.request do
            @raw.describe_events(stack_name: name, change_set_name: change_set_id, filters: { failed_events: true })
          end
          (response.operation_events || []).sort_by { |event| event.timestamp || event.start_time }.map do |event|
            reason = [ event.validation_name, event.validation_status_reason ].compact.join(": ")
            Event.new(
              resource_status: event.resource_status,
              logical_id: event.logical_resource_id,
              resource_type: event.resource_type,
              status_reason: reason.empty? ? event.resource_status_reason : reason,
              timestamp: event.timestamp || event.start_time
            )
          end
        end

        private

        # The options of a client for this region and profile. STS gets the same
        # ones as CloudFormation: the identity is asked of the same credentials.
        def client_options(region)
          Sdk.options_for(region: region, profile: @profile, credentials: @credentials, stub_responses: @stub_responses)
        end

        # The stack as CloudFormation describes it, or nil when there is none.
        def stack_of(name)
          Sdk.request { @raw.describe_stacks(stack_name: name) }.stacks.first
        rescue RequestFailed => e
          raise unless missing?(e)

          nil
        end

        def missing?(error)
          error.code == "ValidationError" && MISSING_STACK.match?(error.message)
        end

        # The SDK takes { key: ..., value: ... }; the engine may give either kind of key.
        def pairs(list, key, value)
          list.map { |pair| { key => pair[key] || pair[key.to_s], value => pair[value] || pair[value.to_s] } }
        end

        # A parameter either carries its value or asks for the deployed one
        # (UsePreviousValue, for a NoEcho value that comes back masked and goes
        # back masked).
        def parameter_pairs(list)
          list.map do |pair|
            key = pair[:parameter_key] || pair["parameter_key"]
            if pair[:use_previous_value]
              { parameter_key: key, use_previous_value: true }
            else
              { parameter_key: key, parameter_value: pair[:parameter_value] || pair["parameter_value"] }
            end
          end
        end

        # A structure of the SDK as a plain Hash, all the way down.
        def plain(value)
          case value
          when Array
            value.map { |item| plain(item) }
          when Hash
            value.transform_values { |item| plain(item) }
          else
            value.respond_to?(:to_h) ? value.to_h.transform_values { |item| plain(item) } : value
          end
        end
      end

      # The object store port. Every call names the bucket's expected owner
      # (architecture section 8): a bucket name is a function of public facts,
      # and somebody else may hold the one that was computed.
      class ObjectStoreClient
        include ObjectStore

        attr_reader :raw

        def initialize(region:, profile: nil, credentials: nil, stub_responses: false)
          @raw = Aws::S3::Client.new(**Sdk.options_for(region: region, profile: profile, credentials: credentials,
            stub_responses: stub_responses))
        end

        # A HEAD request answers with no body, so its error code is generic
        # (NotFound, Forbidden); the status is what tells the two apart.
        #
        #   :mine    the owner check passed
        #   :foreign the bucket exists and is not ours: S3 answers 403
        #   :absent  there is no such bucket: S3 answers 404
        def bucket_state(name, expected_owner:)
          @raw.head_bucket(bucket: name, expected_bucket_owner: expected_owner)
          :mine
        rescue StandardError => e
          case status_of(e)
          when 404
            :absent
          when 403
            :foreign
          else
            raise Sdk.failure_of(e) || e
          end
        end

        # False only when the object is not there. A bucket that is not ours
        # raises: a false here would read as "not uploaded yet".
        def object_exists?(bucket, key, expected_owner:)
          @raw.head_object(bucket: bucket, key: key, expected_bucket_owner: expected_owner)
          true
        rescue StandardError => e
          status = status_of(e)
          raise not_ours(bucket, expected_owner) if status == 403
          raise Sdk.failure_of(e) || e unless status == 404

          false
        end

        # The object goes in encrypted at rest.
        #
        # What is sent is what the CDK's publisher sends with an asset
        # (cdk-assets-lib, lib/private/handlers/files.ts): the object encrypted
        # (ServerSideEncryption), a SHA-256 checksum (ChecksumAlgorithm), and
        # the content type of the file. For a zip that is application/zip; for
        # anything else the CDK takes the type from the file's extension, and so
        # does this, because the same port carries the templates.
        #
        # The checksum: the SDK computes it itself from the algorithm named
        # here. Named, it is SHA-256 as in the CDK; left out, the SDK's own
        # default would be CRC32.
        #
        # The encryption: AES256 is right while the bucket's own default
        # encryption is SSE-S3. The day the bootstrap bucket is encrypted with
        # a KMS key this has to follow, with "aws:kms" and the key, or S3
        # answers EncryptionTypeMismatch. The CDK reads the bucket's
        # configuration to choose (files.ts:120-131); this does not.
        def put(bucket, key, body:, expected_owner:)
          Sdk.request do
            @raw.put_object(
              bucket: bucket,
              key: key,
              body: body,
              expected_bucket_owner: expected_owner,
              server_side_encryption: "AES256",
              checksum_algorithm: "SHA256",
              content_type: content_type_of(key)
            )
          end
          nil
        rescue RequestFailed => e
          raise not_ours(bucket, expected_owner) if REFUSED.include?(e.code)

          raise
        end

        private

        CONTENT_TYPES = { ".zip" => "application/zip", ".json" => "application/json" }.freeze

        # What S3 answers a put when the bucket is not ours, or not ours to write.
        REFUSED = %w[Forbidden AccessDenied].freeze

        def content_type_of(key)
          CONTENT_TYPES[File.extname(key.to_s).downcase] || "application/octet-stream"
        end

        # A 403 on a call that named the owner: the bucket belongs to another
        # account, or these credentials may not touch it. Either way it stops.
        def not_ours(bucket, expected_owner)
          RequestFailed.new("Bucket #{bucket} belongs to another account than #{expected_owner}, or these credentials may not " \
            "touch it (S3 answered 403 Forbidden), so the operation stops. Nothing was uploaded.", code: "Forbidden")
        end

        def status_of(error)
          return error.context.http_response.status_code if error.is_a?(Aws::Errors::ServiceError)

          0
        end
      end
    end
  end
end
