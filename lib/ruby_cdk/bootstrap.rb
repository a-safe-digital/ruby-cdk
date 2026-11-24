# frozen_string_literal: true

require_relative "version"
require_relative "errors"
require_relative "core"
require_relative "cfn"
require_relative "synth"
require_relative "deploy"

module RubyCdk
  # The asset bucket as a stack of this tool's own (architecture §8): a stack
  # named `ruby-cdk-bootstrap` holding one bucket, `ruby-cdk-assets-<account>-<region>`,
  # versioned, encrypted with SSE-S3, with public access blocked and multipart
  # uploads aborted, retained when the stack is deleted, and its policy denying
  # everything that does not come over TLS. A command builds it with `stack`,
  # checks the ground with `pre_flight`, and deploys it with `run` through the
  # deploy engine.
  #
  # This file is the entry of the `bootstrap` component. It loads the pipeline
  # (which brings the tree, the L1 resources and the serializer) and the engine
  # (which brings the ports). It never loads the AWS SDK: the command that calls
  # `run` builds `clients` with `Deploy::Sdk`, which the adapters component owns.
  module Bootstrap
    # The name of the bootstrap stack, as architecture §8 fixes it.
    STACK_NAME = "ruby-cdk-bootstrap"

    # The logical IDs of the two resources. The bucket's logical ID is named in
    # the orphan-bucket refusal, because the import way out has to use it.
    BUCKET_ID = "AssetsBucket"
    POLICY_ID = "BucketPolicy"

    # The stack tag: what integration sweepers and humans recognise it by.
    TAG_NAME = "ruby-cdk"

    # The asset bucket's name: a function of public facts, exactly what
    # Assets.bucket_name answers. It is computed here, and not read from the
    # assets component, because the component map keeps the two apart (an asset
    # is declared by a user's stack, the bucket is this tool's own). A test pins
    # the two to the same bytes, so they cannot drift.
    BUCKET_PREFIX = "ruby-cdk-assets-"

    # Exit 1. The asset bucket exists and is owned by the caller's account, but
    # no bootstrap stack does, so bootstrap cannot adopt it as it is: the two
    # ways out are in the message.
    class OrphanBucket < PreconditionError; end

    # Exit 1. The asset bucket exists and is owned by another account. Nothing
    # is created.
    class ForeignBucket < PreconditionError; end

    # What pre_flight decided, for the command to show before it deploys.
    #
    #   action       :create (a first deploy), :update (the stack is stable) or
    #                :deploy (the engine decides; it refuses a busy stack or one
    #                that needs repair, and deletes and recreates a failed creation)
    #   stack_state  the engine's own state of the stack, one of Deploy::STACK_STATES
    #   bucket       the bucket's name
    #   bucket_state :mine, :foreign or :absent
    Decision = Data.define(:action, :stack_state, :bucket, :bucket_state)

    class << self
      # Builds the bootstrap stack in the App it is given, and returns it. The
      # command synthesizes and deploys it (run does both); a test synthesizes
      # it alone.
      #
      # The App needs a concrete env, because the bucket's name is made of the
      # account and the region. The stack carries the `ruby-cdk` tag with the
      # gem version, so that sweepers and humans recognise it.
      #
      # deployer_arn: the ARN of the principal that reads the assets back out of
      # the bucket, given as `--deployer` by the command. Nothing, or nil: the
      # policy grants the account's own principals (`arn:aws:iam::<account>:root`,
      # the default the CDK's bootstrap template trusts too). The engine refuses
      # to deploy the stack into an account other than its env's, so the root
      # grant always covers the caller, and it cannot go stale the way a session
      # ARN would.
      def stack(app:, deployer_arn: nil)
        unless app.is_a?(App)
          raise UsageError, "Bootstrap.stack builds the bootstrap stack in an App, got #{app.inspect}. " \
            "Create the App with env: RubyCdk::Env.new(account:, region:) and pass it."
        end
        env = app.env
        raise UsageError, MISSING_ENV unless env

        bucket = bucket_name(env.account, env.region)
        stack = Stack.new(app, STACK_NAME, tags: { TAG_NAME => RubyCdk::VERSION })

        assets = stack.resource(BUCKET_ID, "AWS::S3::Bucket",
          BucketName: bucket,
          BucketEncryption: { "ServerSideEncryptionConfiguration" =>
            [ { "ServerSideEncryptionByDefault" => { "SSEAlgorithm" => "AES256" } } ] },
          PublicAccessBlockConfiguration: PUBLIC_ACCESS_BLOCK.dup,
          VersioningConfiguration: { "Status" => "Enabled" },
          LifecycleConfiguration: { "Rules" => [ MULTIPART_RULE.dup ] },
          deletion_policy: :retain,
          update_replace_policy: :retain)

        stack.resource(POLICY_ID, "AWS::S3::BucketPolicy",
          Bucket: Fn.ref(assets),
          PolicyDocument: policy_document(bucket, principal_of(deployer_arn, env.account)))

        stack
      end

      # What has to be true before anything is created, answered as a Decision.
      # The bucket is checked first (one call of the object-store port, with the
      # identity's account as the expected owner), because a bucket that is not
      # ours stops everything; then the stack's state is read through the
      # engine's own machinery, the port that both the adapter and the engine
      # classify with. Nothing here creates anything; the states the engine
      # refuses it refuses itself, with its own words.
      #
      #   stack of the account   bucket :absent            → :create
      #   stack of the account   bucket ours               → refused: OrphanBucket
      #   stack of the account   bucket foreign            → refused: ForeignBucket
      #   stack :review          bucket :absent            → :create (the engine creates again)
      #   stack :review          bucket ours               → refused: OrphanBucket
      #   stack :stable          bucket ours               → :update (the engine's idempotency skips
      #                                                      it when nothing changed)
      #   stack :stable          bucket :absent            → :update; the Decision says so, and run
      #                                                      announces that this deploy does not
      #                                                      recreate the bucket
      #   stack :stable          bucket foreign            → refused: ForeignBucket
      #   stack :rollback_complete  bucket :absent         → :create (the engine deletes the failed
      #                                                      stack and creates again)
      #   stack :rollback_complete  bucket ours            → refused: OrphanBucket
      #   stack :busy            any                       → :deploy (the engine refuses: StackBusy)
      #   stack :rollback_failed any                       → :deploy (the engine refuses: StackNeedsRepair)
      #
      # A stack in :review or :rollback_complete owns nothing: a change set that
      # was never executed, or a first creation that failed, has made no bucket.
      # That is why the bucket rows of those states are the same as :absent.
      def pre_flight(client:, store:, identity:, env:, stack_name: STACK_NAME)
        bucket = bucket_name(env.account, env.region)
        bucket_state = store.bucket_state(bucket, expected_owner: identity.account)
        raise ForeignBucket, foreign_message(bucket, identity.account, env.account) if bucket_state == :foreign

        state = client.stack_state(stack_name)
        action =
          case state
          when :absent, :review, :rollback_complete
            raise OrphanBucket, orphan_message(bucket, stack_name, identity.account) if bucket_state == :mine

            :create
          when :stable
            :update
          else
            # :busy and :rollback_failed. The engine refuses both on its own, with
            # its own words: StackBusy, or StackNeedsRepair with the repair path.
            :deploy
          end

        Decision.new(action: action, stack_state: state, bucket: bucket, bucket_state: bucket_state)
      end

      # The whole of `ruby-cdk bootstrap`, for the command: builds the stack in
      # the App it is given, asks the client who the credentials are for, runs
      # the pre-flight, synthesizes (locally, before any request), and deploys
      # through the engine. Answers the engine's DeployResult, whose exit_code
      # is the command's.
      #
      # clients is the pair the adapters build (Sdk.clients: cfn and store).
      # options is a Deploy::DeployOptions; yes comes from the command, which
      # owns --yes. Nothing is published: the bootstrap stack has no assets,
      # and a stack with no assets uploads nothing.
      def run(app:, clients:, output:, deployer_arn: nil, options: nil)
        stack = Bootstrap.stack(app:, deployer_arn:)
        identity = clients.cfn.resolve_identity
        decision = pre_flight(client: clients.cfn, store: clients.store, identity:, env: stack.env,
          stack_name: stack.stack_name)
        output.announce(missing_bucket_note(decision, stack.stack_name)) if missing_bucket?(decision)

        synthesized = Synth.synthesize(stack)
        Deploy::Deployer.new(client: clients.cfn, store: clients.store, output:).deploy(
          stack: stack, template: synthesized.bytes, identity: identity, options: options || Deploy::DeployOptions.new
        )
      end

      # The asset bucket of an account in a region: the same bytes
      # Assets.bucket_name answers (see BUCKET_PREFIX above).
      def bucket_name(account, region)
        "#{BUCKET_PREFIX}#{account}-#{region}"
      end

      private

      # Public access blocked on all four settings, as architecture §8 asks.
      # The resource takes its own copy: properties belong to the resource.
      PUBLIC_ACCESS_BLOCK = {
        "BlockPublicAcls" => true,
        "BlockPublicPolicy" => true,
        "IgnorePublicAcls" => true,
        "RestrictPublicBuckets" => true
      }.freeze

      # Incomplete multipart uploads are aborted a day after they start: an
      # asset zip finishes in minutes, so anything older is a leftover that
      # would otherwise be billed forever.
      MULTIPART_RULE = {
        "Id" => "abort-incomplete-multipart-uploads",
        "Status" => "Enabled",
        "AbortIncompleteMultipartUpload" => { "DaysAfterInitiation" => 1 }
      }.freeze

      MISSING_ENV = "Bootstrap needs a concrete env, because the asset bucket's name is made of the account and " \
        "the region (ruby-cdk-assets-<account>-<region>). Create the App with env: RubyCdk::Env.new(account:, region:)."

      def principal_of(deployer_arn, account)
        return "arn:aws:iam::#{account}:root" if deployer_arn.nil?

        arn = deployer_arn.to_s
        if arn.strip.empty?
          raise UsageError, "Bootstrap: deployer_arn was given blank (#{deployer_arn.inspect}). Give the ARN of the " \
            "principal that reads the assets (--deployer arn:aws:iam::<account>:role/deployer), or nothing, to grant " \
            "the account's own principals."
        end

        arn
      end

      # The two statements of the bucket's policy: deny everything that does not
      # come over TLS, on the bucket and on its objects; and let the deployer
      # read the objects back, because CloudFormation reads a TemplateURL with
      # the caller's permissions, so the grant has to name it (architecture §8).
      # Asset keys sit at the root as <hash>.zip, so the read is on every object.
      def policy_document(bucket, principal)
        {
          "Version" => "2012-10-17",
          "Statement" => [
            {
              "Sid" => "DenyInsecureTransport",
              "Effect" => "Deny",
              "Principal" => "*",
              "Action" => "s3:*",
              "Resource" => [ "arn:aws:s3:::#{bucket}", "arn:aws:s3:::#{bucket}/*" ],
              "Condition" => { "Bool" => { "aws:SecureTransport" => "false" } }
            },
            {
              "Sid" => "DeployerReadsAssets",
              "Effect" => "Allow",
              "Principal" => { "AWS" => principal },
              "Action" => "s3:GetObject",
              "Resource" => "arn:aws:s3:::#{bucket}/*"
            }
          ]
        }
      end

      # The bucket exists and is ours, but no bootstrap stack does: bootstrap
      # cannot go on, and there are two ways out (architecture §8).
      def orphan_message(bucket, stack_name, account)
        "The asset bucket #{bucket} exists in account #{account}, but the bootstrap stack #{stack_name} does not, " \
          "so bootstrap stops: creating the stack would try to make a bucket that already has that name. " \
          "Nothing was created or changed.\n" \
          "Two ways out:\n" \
          "  - the bucket is empty: empty it and delete it in the S3 console, then run `ruby-cdk bootstrap` again;\n" \
          "  - the bucket holds objects to keep: import the bucket into stack #{stack_name} with CloudFormation " \
          "resource import (a change set of type IMPORT, logical ID #{BUCKET_ID}), then run `ruby-cdk bootstrap` again."
      end

      # The bucket exists and is not ours: bootstrap stops before anything is
      # created (architecture §8, D-008: the name is a function of public facts).
      def foreign_message(bucket, identity_account, env_account)
        "The asset bucket #{bucket} exists, but it is not owned by account #{identity_account}, which is who the " \
          "credentials are for (S3 answers 403 Forbidden when a bucket belongs to another account), so bootstrap " \
          "stops before anything is created. Bucket names are global: whoever holds the name would receive what " \
          "this tool uploads to it.\n" \
          "Run the command again with credentials of account #{env_account}, the one the stack's env names " \
          "(--profile NAME), or give the App an env for the account these credentials are for."
      end

      # The stack is there and the bucket is not. Deploying does not mend it:
      # the bucket's name is part of the deployed template, so CloudFormation
      # sees no change and makes no bucket. The first deploy of a stack with
      # assets then refuses ("Run `ruby-cdk bootstrap` first"), which is the
      # honest outcome, but it should not be a surprise.
      def missing_bucket?(decision)
        decision.action == :update && decision.bucket_state == :absent
      end

      def missing_bucket_note(decision, stack_name)
        "The asset bucket #{decision.bucket} does not exist, although the bootstrap stack #{stack_name} does. " \
          "This deploy does not recreate a bucket the template already names, and the first deploy of a stack " \
          "with assets will refuse until the bucket is there. If the bucket was deleted by hand, destroy the " \
          "bootstrap stack (`ruby-cdk destroy #{stack_name}`), then run `ruby-cdk bootstrap` again."
      end
    end
  end
end
