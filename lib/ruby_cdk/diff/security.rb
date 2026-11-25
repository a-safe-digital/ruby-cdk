# frozen_string_literal: true

require_relative "statement"

module RubyCdk
  module Diff
    # The security view of a diff (architecture section 10): the IAM
    # statements a deployment adds or takes away, and the managed policies it
    # attaches, in a table of their own, with the capabilities the new
    # template needs that the deployed one did not.
    #
    # The CDK's view is a heuristic: it reads a property only where AWS's
    # service metadata says the property may carry a policy, and warns for it
    # ("There may be security-related changes not in this list", its issue
    # 1299). Ours is exact by resource type and by the statements the template
    # carries: every resource of both templates is walked for the property
    # names that carry policy documents anywhere AWS publishes one, so a
    # statement cannot hide in a type the metadata does not mention. That is
    # the one line the command's help says it with.
    class Security
      # The property names that carry an IAM policy document, wherever AWS
      # publishes one: identity policies, resource policies, trust policies,
      # key policies, repository and domain access policies alike.
      POLICY_PROPERTIES = %w[PolicyDocument AssumeRolePolicyDocument KeyPolicy RepositoryPolicyText AccessPolicies].freeze

      # The identities whose inline Policies carry statements that apply to
      # the identity itself.
      IDENTITY_TYPES = %w[
        AWS::IAM::Role
        AWS::IAM::User
        AWS::IAM::Group
      ].freeze

      # The resource types whose one job is a policy attached to another
      # resource: the statement's resource is the sibling property that names
      # it.
      ATTACHED_POLICY_TYPES = %w[
        AWS::S3::BucketPolicy
        AWS::SQS::QueuePolicy
        AWS::SNS::TopicPolicy
      ].freeze

      # The types CloudFormation refuses a change set without a capability
      # for, and the properties that name an IAM resource explicitly. The same
      # eight types and five names deploy reads (deploy/capabilities.rb, both
      # from CloudFormation's change-set reference): the diff component reads a
      # table of its own, because the engine is not among its dependencies.
      CAPABILITY_TYPES = %w[
        AWS::IAM::AccessKey
        AWS::IAM::Group
        AWS::IAM::InstanceProfile
        AWS::IAM::ManagedPolicy
        AWS::IAM::Policy
        AWS::IAM::Role
        AWS::IAM::User
        AWS::IAM::UserToGroupAddition
      ].freeze
      NAME_PROPERTIES = %w[RoleName ManagedPolicyName UserName GroupName InstanceProfileName].freeze

      # One managed policy attachment: an identity, and the ARN attached to it.
      Attachment = Data.define(:identity, :arn) do
        def equal?(other)
          identity == other.identity && arn == other.arn
        end

        def to_h
          { "identity" => identity, "arn" => arn }
        end
      end

      # The statements of each side of the diff: additions are the ones the new
      # template carries that the deployed one does not, removals the reverse.
      # Managed policies the same, as attachments of an identity to an ARN.
      attr_reader :statement_additions, :statement_removals, :managed_policy_additions, :managed_policy_removals
      attr_reader :capabilities_added

      def self.build(diff)
        statements_old = []
        statements_new = []
        policies_old = []
        policies_new = []

        diff.resources.each_value do |change|
          statements_old.concat(change_statements(change, :old))
          statements_new.concat(change_statements(change, :new))
          policies_old.concat(managed_policies(change, :old))
          policies_new.concat(managed_policies(change, :new))
        end

        capabilities = capability_set(diff_resources(diff, :new)) - capability_set(diff_resources(diff, :old))
        new(statement_additions: added(statements_new, statements_old), statement_removals: added(statements_old, statements_new),
          managed_policy_additions: added(policies_new, policies_old), managed_policy_removals: added(policies_old, policies_new),
          capabilities_added: capabilities)
      end

      def initialize(statement_additions:, statement_removals:, managed_policy_additions:, managed_policy_removals:, capabilities_added:)
        @statement_additions = statement_additions.freeze
        @statement_removals = statement_removals.freeze
        @managed_policy_additions = managed_policy_additions.freeze
        @managed_policy_removals = managed_policy_removals.freeze
        @capabilities_added = capabilities_added.freeze
      end

      def has_changes?
        statement_additions.any? || statement_removals.any? || managed_policy_additions.any? ||
          managed_policy_removals.any? || capabilities_added.any?
      end

      # True when the deployment widens what the deployed template may do, the
      # CDK's permissionsBroadened: a positive statement granted, a negative
      # one taken away, a managed policy attached.
      def broadening?
        statement_additions.any? { |statement| !statement.negative? } ||
          statement_removals.any?(&:negative?) ||
          managed_policy_additions.any?
      end

      # True when the change of this resource is one the security view owns: a
      # capability-affecting type, a policy document it carries, or a managed
      # policy it attaches, on either side of the diff.
      def security_change?(change)
        [ change.old_type, change.new_type ].compact.any? { |type| CAPABILITY_TYPES.include?(type) } ||
          change.old_type == "AWS::Lambda::Permission" || change.new_type == "AWS::Lambda::Permission" ||
          self.class.properties_of(change, :old)&.key?("ManagedPolicyArns") ||
          self.class.properties_of(change, :new)&.key?("ManagedPolicyArns") ||
          self.class.watched_property?(self.class.properties_of(change, :old)) ||
          self.class.watched_property?(self.class.properties_of(change, :new))
      end

      # The whole view for --json.
      def to_h
        {
          "broadening" => broadening?,
          "has_changes" => has_changes?,
          "capabilities_added" => capabilities_added,
          "statements" => {
            "additions" => statement_additions.map(&:to_h),
            "removals" => statement_removals.map(&:to_h)
          },
          "managed_policies" => {
            "additions" => managed_policy_additions.map(&:to_h),
            "removals" => managed_policy_removals.map(&:to_h)
          }
        }
      end

      # --- the walk that finds what a template carries

      # The statements of one side of one resource's change.
      def self.change_statements(change, side)
        type = side == :old ? change.old_type : change.new_type
        properties = properties_of(change, side)
        return [] if type.nil? || !properties.is_a?(Hash)

        read_statements(type, properties, change.logical_id)
      end

      def self.managed_policies(change, side)
        properties = properties_of(change, side)
        return [] unless properties.is_a?(Hash) && properties.key?("ManagedPolicyArns")

        arns = RenderIntrinsics.call(properties["ManagedPolicyArns"])
        Array(arns).map { |arn| Attachment.new(identity: "${#{change.logical_id}}", arn: arn) }
      end

      def self.properties_of(change, side)
        value = side == :old ? change.old_value : change.new_value
        value.is_a?(Hash) ? value["Properties"] : nil
      end

      # The resource definitions of one side, for the capability table.
      def self.diff_resources(diff, side)
        diff.resources.each_value.filter_map do |change|
          value = side == :old ? change.old_value : change.new_value
          value if value.is_a?(Hash)
        end
      end

      # Multiset difference: what one side carries that the other does not,
      # matched one entry to one entry by what it says.
      def self.added(entries, against)
        unmatched = against.dup
        entries.reject do |entry|
          at = unmatched.find_index { |candidate| candidate.equal?(entry) }
          if at.nil?
            false
          else
            unmatched.delete_at(at)
            true
          end
        end
      end

      # True when any of the properties is one this view reads.
      def self.watched_property?(properties)
        return false unless properties.is_a?(Hash)

        walk(properties).any?
      end

      # The statements one resource's properties carry, exact by resource type.
      def self.read_statements(type, properties, logical_id)
        rendered = RenderIntrinsics.call(properties)

        return [ Statement.from_lambda_permission(rendered) ] if type == "AWS::Lambda::Permission"
        return identity_policy_resource(rendered, logical_id) if type == "AWS::IAM::Policy"
        return attached_policy_resource(rendered) if ATTACHED_POLICY_TYPES.include?(type)

        statements = []
        walk(rendered) { |path, value| statements.concat(policy_statements(type, path, value, logical_id)) }
        statements
      end

      # The walk: every property whose name carries a policy document, at any
      # depth of the resource's properties. This is what makes the view exact:
      # nothing the template carries as a statement can walk past it. Without
      # a block it answers the enumerator of the hits.
      def self.walk(value, path = [], &block)
        return enum_for(:walk, value, path) unless block

        case value
        when Hash
          value.each do |key, entry|
            here = path + [ key ]
            if POLICY_PROPERTIES.include?(key)
              block.call(here, entry)
            else
              walk(entry, here, &block)
            end
          end
        when Array
          value.each_with_index { |entry, index| walk(entry, path + [ index ], &block) }
        end
      end

      # The statements of one policy document found at one path, with the
      # defaults the place gives them:
      #
      # - the inline Policies of a Role, User or Group apply to the identity
      #   itself: their principal is the resource (the CDK's
      #   readIdentityPolicies);
      # - every other policy document applies to the resource that carries it,
      #   where the statement does not name one (the CDK's
      #   readResourceStatements).
      def self.policy_statements(type, path, value, logical_id)
        document = value.is_a?(Hash) && value["Statement"] ? value : nil
        return [] unless document

        statements = parse_statements(document["Statement"])
        if IDENTITY_TYPES.include?(type) && path.include?("Policies")
          statements.each { |statement| statement.principals.replace_empty_or_star("AWS:${#{logical_id}}") }
        else
          statements.each { |statement| statement.resources.replace_empty_or_star("${#{logical_id}.Arn}") }
        end
        statements
      end

      # AWS::IAM::Policy: one statement set per principal the policy attaches
      # to, each "AWS:" plus what the Roles, Users and Groups name (the CDK's
      # readIdentityPolicyResource).
      def self.identity_policy_resource(properties, logical_id)
        principals = Array(properties["Groups"]) + Array(properties["Users"]) + Array(properties["Roles"])
        document = properties["PolicyDocument"]
        return [] unless document.is_a?(Hash)

        principals.flat_map do |principal|
          statements = parse_statements(document["Statement"])
          statements.each { |statement| statement.principals.replace_empty_or_star("AWS:#{principal}") }
        end
      end

      # The policies attached to a resource of their own (a bucket policy, a
      # queue policy, a topic policy): the statement's resource is the
      # property that names the resource, the one key that is neither a policy
      # nor a name (the CDK's readResourcePolicyResource).
      def self.attached_policy_resource(properties)
        policy_keys = properties.keys.select { |key| key.include?("Policy") }
        resource_keys = properties.keys.select { |key| !policy_keys.include?(key) && !key.end_with?("Name") }
        resources = resource_keys.length == 1 ? properties[resource_keys.first] : "???"
        policy_key = policy_keys.first
        return [] if policy_key.nil? || !properties[policy_key].is_a?(Hash)

        Array(resources).flat_map do |resource|
          statements = parse_statements(properties[policy_key]["Statement"])
          statements.each { |statement| statement.resources.replace_empty_or_star(resource) }
        end
      end

      # parseStatements: one statement or a list of them. A Hash is one
      # statement, never a list of pairs.
      def self.parse_statements(value)
        statements = if value.nil?
          []
        elsif value.is_a?(Array)
          value
        else
          [ value ]
        end
        statements.map { |statement| Statement.new(statement) }
      end

      # The capabilities a template's resources ask of CloudFormation:
      # CAPABILITY_IAM for any of the eight types, CAPABILITY_NAMED_IAM with it
      # when one of them is named explicitly. The answer deploy computes for
      # the change set, computed here for the view.
      def self.capability_set(resources)
        iam = resources.select { |resource| CAPABILITY_TYPES.include?(resource["Type"]) }
        return [] if iam.empty?

        named = iam.any? do |resource|
          properties = resource["Properties"]
          properties.is_a?(Hash) && NAME_PROPERTIES.any? { |property| !properties[property].nil? }
        end
        named ? %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM] : %w[CAPABILITY_IAM]
      end

      private_class_method :change_statements, :managed_policies, :diff_resources, :added,
        :read_statements, :walk, :policy_statements, :identity_policy_resource,
        :attached_policy_resource, :parse_statements, :capability_set
    end
  end
end
