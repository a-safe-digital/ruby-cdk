# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "../lazy"
require_relative "policy_statement"
require_relative "grant"

module RubyCdk
  module IAM
    # An IAM role: the port of the CDK's Role (aws-iam/lib/role.ts), read at
    # commit c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   RubyCdk::IAM::Role.new(stack, "Role",
    #     assumed_by: "lambda.amazonaws.com",
    #     managed_policy_arns: ["arn:aws:iam::aws:policy/ReadOnlyAccess"])
    #
    # `assumed_by` builds the AssumeRolePolicyDocument (role.ts,
    # createAssumeRolePolicy): one Allow statement per principal, Action
    # "sts:AssumeRole". A principal is a service name ("lambda.amazonaws.com"
    # becomes Service), an ARN or an account id (both become AWS, as written),
    # "*" (AnyPrincipal, which the CDK writes as { AWS: "*" } in a trust
    # policy), a Hash taken verbatim, or a list of any of these (the CDK's
    # CompositePrincipal, one statement each).
    #
    # Statements join the role's policy the CDK's ways (role.ts:653-661,
    # addToPrincipalPolicy):
    #
    #   - add_to_policy(statement) and attach_policy(statement) - the same
    #     thing, both named after how they are read - create or extend the
    #     role's DefaultPolicy resource, an AWS::IAM::Policy whose logical ID
    #     is the role's with DefaultPolicy behind it and whose PolicyName is
    #     that logical ID, as the CDK's generatePolicyName takes the logical ID
    #     (aws-iam/lib/private/util.ts). The statements sit behind a Lazy, so
    #     grants applied after the role was built are all there.
    #   - to_inline_policy(statements, name:) writes a named policy into the
    #     role's Policies list, the CDK's inlinePolicies prop (role.ts:112).
    #
    # The grant_* friends make the role the principal other constructs grant
    # to, the CDK's IGrantable (role.ts:462, grantPrincipal = this):
    # grant(principal, ...actions) is the CDK's Role#grant - the actions on the
    # role's ARN - and grant_pass_role and grant_assume_role its two named
    # ones (role.ts:704-732).
    #
    # Used twice in one stack, each role carries its own Resource and
    # DefaultPolicy under its own logical ID.
    class Role < Construct
      # The CDK's rule for a role name (role.ts, InvalidRoleName): IAM's own.
      ROLE_NAME_PATTERN = /\A[\w+=,.@-]{1,64}\z/

      # The CDK's bounds for maxSessionDuration (role.ts, validateMaxSessionDuration).
      MIN_SESSION_DURATION = 3600
      MAX_SESSION_DURATION = 43_200

      # The CDK's bound for the description (role.ts, RoleDescriptionLongerCharacters).
      MAX_DESCRIPTION_LENGTH = 1000

      # The action of every trust policy.
      ASSUME_ROLE_ACTION = "sts:AssumeRole"

      attr_reader :assumed_by, :managed_policy_arns

      def initialize(scope, id, assumed_by:, managed_policy_arns: [], role_name: nil, description: nil, max_session_duration: nil)
        super(scope, id)
        @assumed_by = assumed_by
        @role_name = valid_role_name(role_name)
        @description = valid_description(description)
        @session_duration = valid_session_duration(max_session_duration)
        @statements = []
        @inline_policies = {}
        @policy = nil

        # Managed policy ARNs can be added after the role was built, so the
        # property reads them when the stack is resolved.
        @managed_policy_arns = []
        managed_policy_arns.each { |arn| add_managed_policy(arn) }

        @resource = resource("Resource", "AWS::IAM::Role",
          AssumeRolePolicyDocument: assume_role_policy_document,
          ManagedPolicyArns: Lazy.new { @managed_policy_arns.empty? ? nil : @managed_policy_arns },
          Policies: Lazy.new { inline_policies_property },
          RoleName: @role_name,
          MaxSessionDuration: @session_duration,
          Description: @description)
      end

      # The logical ID of the AWS::IAM::Role under this construct, so that the
      # role can sit in another resource's depends_on:.
      def logical_id
        @resource.logical_id
      end

      # The role's ARN.
      def arn
        Fn.get_att(@resource, "Arn")
      end

      alias principal_arn arn

      # The role's name: the one given, or the Ref of the resource.
      def role_name
        @role_name || Fn.ref(@resource)
      end

      # This role is what other constructs' grant_* grant to: the CDK's
      # IGrantable (role.ts:462, grantPrincipal = this).
      def grant_principal
        self
      end

      # Adds a statement to the role's DefaultPolicy, creating it on the first
      # call (role.ts:653-661). statement is an IAM::PolicyStatement or a Hash
      # in CloudFormation's statement shape.
      #
      # attach_policy is the same method under its other name.
      def add_to_policy(statement)
        @statements << as_statement(statement)
        @policy ||= resource("DefaultPolicy", "AWS::IAM::Policy",
          PolicyDocument: Lazy.new { policy_document(@statements) },
          PolicyName: Lazy.new { policy_name },
          Roles: [ Fn.ref(@resource) ])
        self
      end

      alias attach_policy add_to_policy

      # Writes a named inline policy into the role's Policies list, the CDK's
      # inlinePolicies prop (role.ts:112, _flatten at :594): one
      # { PolicyName, PolicyDocument } per name. A name used twice is refused,
      # as two attached policies of one name are in the CDK
      # (aws-iam/lib/private/util.ts, PolicyNamedAlreadyAttached).
      def to_inline_policy(statements, name:)
        unless name.is_a?(String) && !name.empty?
          raise UsageError, "#{path}: to_inline_policy takes a name:, got #{name.inspect}"
        end
        if @inline_policies.key?(name)
          raise UsageError, "#{path}: there is already an inline policy named #{name.inspect} on this role"
        end

        list = Array(statements).map { |statement| as_statement(statement) }
        raise UsageError, "#{path}: to_inline_policy takes at least one statement" if list.empty?

        @inline_policies[name] = list
        self
      end

      # Adds a managed policy ARN, later included; the same ARN twice adds
      # nothing, as the CDK's UniqueStringSet dedupes (role.ts:601).
      def add_managed_policy(arn)
        unless arn.is_a?(String) && !arn.empty?
          raise UsageError, "#{path}: add_managed_policy takes a policy ARN, got #{arn.inspect}"
        end

        @managed_policy_arns << arn unless @managed_policy_arns.include?(arn)
        self
      end

      # Grants the actions on this role's ARN to the principal: the CDK's
      # Role#grant (role.ts:704-711).
      def grant(principal, *actions)
        Constructs::Grant.add_to_principal(principal, actions, [ arn ])
      end

      # Grants iam:PassRole on this role to the principal (role.ts:716-721).
      def grant_pass_role(principal)
        grant(principal, "iam:PassRole")
      end

      # Grants sts:AssumeRole on this role to the principal (role.ts:726-732).
      # A service or account principal cannot assume a role this way - the CDK
      # refuses one with "use assumeRolePolicy instead", and so does this.
      def grant_assume_role(principal)
        unless assumable_principal?(principal)
          raise UsageError,
            "Cannot use a service or account principal with grant_assume_role, use the assume_role_policy instead " \
            "(give assumed_by: to a new role, or grant a principal named by its ARN)"
        end

        grant(principal, ASSUME_ROLE_ACTION)
      end

      private

      def valid_role_name(name)
        return nil if name.nil?
        return name if name.is_a?(String) && name.match?(ROLE_NAME_PATTERN)

        raise UsageError, "#{path}: the role name must be 1 to 64 characters of letters, digits and _+=,.@-, got #{name.inspect}"
      end

      def valid_description(description)
        return nil if description.nil? || (description.is_a?(String) && description.empty?)
        return description if description.is_a?(String) && description.length <= MAX_DESCRIPTION_LENGTH

        raise UsageError, "#{path}: the description must be at most #{MAX_DESCRIPTION_LENGTH} characters, got #{description.length}"
      end

      def valid_session_duration(duration)
        return nil if duration.nil?
        return duration if duration.is_a?(Integer) && duration.between?(MIN_SESSION_DURATION, MAX_SESSION_DURATION)

        raise UsageError, "#{path}: max_session_duration is set to #{duration.inspect}, but must be between " \
          "#{MIN_SESSION_DURATION} (1h) and #{MAX_SESSION_DURATION} (12h) seconds"
      end

      def as_statement(statement)
        return statement if statement.is_a?(PolicyStatement)
        return statement if statement.is_a?(Hash)

        raise UsageError, "#{path}: a policy statement is an IAM::PolicyStatement or a Hash in CloudFormation's shape, got #{statement.inspect}"
      end

      # The statement as the template holds it: a PolicyStatement renders
      # itself, a Hash is taken verbatim with its keys as the user wrote them.
      def statement_rendered(statement)
        return statement.to_statement if statement.is_a?(PolicyStatement)

        statement.to_h { |key, value| [ key.to_s, value ] }
      end

      # One Allow statement per principal, the CDK's trust policy
      # (createAssumeRolePolicy, role.ts:881-894; its CompositePrincipal test).
      def assume_role_policy_document
        {
          "Version" => "2012-10-17",
          "Statement" => assumed_by_principals.map { |principal| assume_statement(principal).to_statement }
        }
      end

      def assumed_by_principals
        list = @assumed_by.is_a?(Array) ? @assumed_by : [ @assumed_by ]
        raise UsageError, "#{path}: assumed_by takes a principal or a list of them, got #{@assumed_by.inspect}" if list.empty?

        list.map { |principal| principal.is_a?(Hash) ? stringify_keys(principal) : principal }
      end

      def assume_statement(principal)
        IAM::PolicyStatement.new(
          actions: [ ASSUME_ROLE_ACTION ],
          # The CDK writes AnyPrincipal in a trust policy as { AWS: "*" }
          # (role.ts, its "Principal-* gets translated" test): a bare "*" is
          # refused by CreateRole there.
          principals: principal == "*" ? { "AWS" => "*" } : principal
        )
      end

      def stringify_keys(hash)
        hash.to_h { |key, value| [ key.to_s, value ] }
      end

      # The DefaultPolicy's document, once the statements are in.
      def policy_document(statements)
        { "Version" => "2012-10-17", "Statement" => statements.map { |statement| statement_rendered(statement) } }
      end

      # The CDK names an inline policy after its logical ID, last 128
      # characters (aws-iam/lib/private/util.ts, generatePolicyName).
      def policy_name
        logical = @policy.logical_id
        logical.length > 128 ? logical[-128..] : logical
      end

      def inline_policies_property
        return nil if @inline_policies.empty?

        @inline_policies.map do |name, statements|
          { "PolicyName" => name, "PolicyDocument" => policy_document(statements) }
        end
      end

      # A principal that can be granted sts:AssumeRole on: an IAM::Role, or an
      # ARN. A service name or an account id is refused (role.ts, its two
      # "cannot grant AssumeRole" tests).
      def assumable_principal?(principal)
        return true if principal.is_a?(IAM::Role)
        return principal.is_a?(String) && principal.start_with?("arn:") if principal.is_a?(String)

        false
      end
    end
  end
end
