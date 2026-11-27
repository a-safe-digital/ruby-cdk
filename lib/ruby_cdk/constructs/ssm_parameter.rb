# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "../lazy"
require_relative "grant"

module RubyCdk
  module SSM
    # An SSM parameter: the port of the CDK's StringParameter and
    # StringListParameter (aws-ssm/lib/parameter.ts), read at commit
    # c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   RubyCdk::SSM::Parameter.new(stack, "Token",
    #     name: "/app/token", value: secret, type: :string)
    #   RubyCdk::SSM::Parameter.new(stack, "Hosts",
    #     value: ["a.internal", "b.internal"], type: :string_list)
    #
    # The CDK splits the two kinds over two classes; here one class takes
    # type: :string or :string_list, the two values the model lists for the
    # Type property, and writes Type accordingly. The CDK's StringParameter
    # writes ParameterType.STRING (parameter.ts:759), the StringListParameter
    # ParameterType.STRING_LIST (parameter.ts:889); a string list is joined
    # with a comma, as the CDK's Fn.join(',', props.stringListValue) is
    # (parameter.ts:890), and a literal list resolves to the joined string.
    #
    # The value may be an intrinsic - Fn.sub of a deploy-time value - and the
    # allowed_pattern is then not checked, as the CDK leaves unresolved tokens
    # alone (_assertValidValue, parameter.ts:915-925). The name checks are the
    # CDK's: at most 2048 characters and only letters, digits and .-_/
    # (validateParameterName, parameter.ts:929-937), and a name with a slash
    # must begin with one, as the ARN builder requires (util.ts:21-23).
    #
    # SecureString is refused: the CDK itself says a SecureString parameter
    # cannot be created directly (parameter.ts:311-315), the model lists only
    # String and StringList for Type, and a SecureString value is encrypted
    # with a KMS key - reading it needs kms:Decrypt on that key, which this
    # wave's grants cannot carry without a Key construct. Reference one with
    # Fn.sub("{{resolve:ssm-secure:...}}") on the reader's side instead, or
    # wait for the KMS Key construct.
    #
    # The ARN has no GetAtt on this type: it is built from the name, as the
    # CDK's arnForParameterName builds it (util.ts:17-46) - simple name and
    # path name read the same here, "parameter" then the name without its
    # leading slash. Built with Fn.sub over CloudFormation's own pseudo
    # parameters, so it works in a stack with no concrete env.
    #
    # The grants are the CDK's (parameter.ts:203-231, at the pinned commit):
    # read is ssm:DescribeParameters, ssm:GetParameters, ssm:GetParameter and
    # ssm:GetParameterHistory, in that order; write is ssm:PutParameter. All
    # on the ARN, to the principal's own policy. The CDK adds
    # encryptionKey.grantDecrypt/grantEncrypt beside them when the parameter
    # carries a KMS key prop; there is no key prop here, so no KMS actions
    # travel with the grant, as in the CDK without one.
    class Parameter < Construct
      # The CDK's two createable types (parameter.ts:759, 889).
      TYPES = { string: "String", string_list: "StringList" }.freeze

      # The CDK's tiers (parameter.ts:343-356).
      TIERS = { standard: "Standard", advanced: "Advanced", intelligent_tiering: "Intelligent-Tiering" }.freeze

      # The CDK's data types (parameter.ts:329-338).
      DATA_TYPES = [ "text", "aws:ec2:image" ].freeze

      # The CDK's read actions, in its order (parameter.ts:209-214).
      READ_ACTIONS = [
        "ssm:DescribeParameters", "ssm:GetParameters", "ssm:GetParameter", "ssm:GetParameterHistory"
      ].freeze

      # The CDK's write action (parameter.ts:228).
      WRITE_ACTIONS = [ "ssm:PutParameter" ].freeze

      attr_reader :type

      def initialize(scope, id, value:, type: :string, name: nil, description: nil, allowed_pattern: nil,
        tier: nil, data_type: nil)
        super(scope, id)
        @type = valid_type(type)
        @name = valid_name(name)
        @description = valid_description(description)
        @tier = valid_tier(tier)
        @data_type = valid_data_type(data_type)
        @values = valid_values(value, allowed_pattern)

        @resource = resource("Resource", "AWS::SSM::Parameter",
          Name: @name,
          Type: TYPES[@type],
          Value: rendered_value,
          Description: @description,
          AllowedPattern: allowed_pattern,
          Tier: @tier,
          DataType: @data_type)
      end

      # The logical ID of the AWS::SSM::Parameter under this construct, so that
      # the parameter can sit in another resource's depends_on:.
      def logical_id
        @resource.logical_id
      end

      # The parameter's name: the one given, or the Ref of the resource, as the
      # CDK's parameterName is the resource's ref (parameter.ts:766).
      def parameter_name
        @name || Fn.ref(@resource)
      end

      # The parameter's ARN, built from the name (parameter.ts:767-770 and
      # util.ts, arnForParameterName).
      def arn
        Fn.sub("arn:${AWS::Partition}:ssm:${AWS::Region}:${AWS::AccountId}:parameter/${ParameterName}",
          "ParameterName" => @name ? @name.delete_prefix("/") : Fn.ref(@resource))
      end

      # Grants the read actions to the principal (parameter.ts:203-217). The
      # CDK adds a KMS grantDecrypt beside them when the parameter carries an
      # encryption key; there is no key prop here, so the four SSM actions
      # alone travel with the grant.
      def grant_read(principal)
        Constructs::Grant.add_to_principal(principal, READ_ACTIONS, [ arn ])
      end

      # Grants the write action (parameter.ts:222-231).
      def grant_write(principal)
        Constructs::Grant.add_to_principal(principal, WRITE_ACTIONS, [ arn ])
      end

      private

      # :secure_string is refused with the KMS implication spelled out; see the
      # header.
      def valid_type(value)
        return value if TYPES.key?(value)

        raise UsageError, "#{path}: type takes :string or :string_list (SecureString is not createable: the CDK " \
          "says so itself, parameter.ts:311-315, and reading one needs kms:Decrypt on its KMS key), got #{value.inspect}"
      end

      def valid_name(name)
        return nil if name.nil?
        raise UsageError, "#{path}: the name must be a String, got #{name.inspect}" unless name.is_a?(String)
        raise UsageError, "#{path}: name cannot be longer than 2048 characters." if name.length > 2048
        unless name.match?(%r{\A[/\w.-]+\z})
          raise UsageError, "#{path}: name must only contain letters, numbers, and the following 4 symbols .-_\/; got #{name}"
        end
        if name.include?("/") && !name.start_with?("/")
          raise UsageError, "#{path}: Parameter names must be fully qualified " \
            "(if they include \"/\" they must also begin with a \"/\"): #{name}"
        end

        name
      end

      def valid_description(description)
        return nil if description.nil?
        unless description.is_a?(String)
          raise UsageError, "#{path}: the description must be a String, got #{description.inspect}"
        end
        raise UsageError, "#{path}: Description cannot be longer than 1024 characters." if description.length > 1024

        description
      end

      def valid_tier(tier)
        return nil if tier.nil?
        return TIERS[tier] if TIERS.key?(tier)

        raise UsageError, "#{path}: tier takes #{TIERS.keys.map(&:inspect).join(", ")}, got #{tier.inspect}"
      end

      def valid_data_type(data_type)
        return nil if data_type.nil?
        return data_type if DATA_TYPES.include?(data_type)

        raise UsageError, "#{path}: data_type takes #{DATA_TYPES.map(&:inspect).join(" or ")}, got #{data_type.inspect}"
      end

      # The value: a String or an intrinsic for :string, a list of them for
      # :string_list. Literal values are checked against the allowed_pattern,
      # as the CDK checks them (parameter.ts:740-742, 874-876); intrinsics are
      # left alone, as its _assertValidValue leaves unresolved tokens.
      def valid_values(value, allowed_pattern)
        list = value.is_a?(Array) ? value : [ value ]
        if @type == :string && value.is_a?(Array)
          raise UsageError, "#{path}: a :string parameter takes one value, got an Array of #{value.length}"
        end
        list.each { |item| assert_value_kind(item) }
        list.each { |item| assert_valid_value(item, allowed_pattern) }
        list.each { |item| assert_no_comma(item) } if @type == :string_list
        list
      end

      # A value is a String, an intrinsic or a Lazy; anything else is refused
      # here rather than left for the value model, the way a physical name is.
      def assert_value_kind(item)
        return if item.is_a?(String) || item.is_a?(Hash) || item.is_a?(Lazy)

        raise UsageError, "#{path}: the value must be a String, an intrinsic or a Lazy, got #{item.inspect}"
      end

      # The CDK's _assertValidValue (parameter.ts:915-925): a literal is tested
      # with the pattern, unanchored, as RegExp#test is. A Hash (an intrinsic)
      # or a Lazy is left alone.
      def assert_valid_value(item, pattern)
        return if item.is_a?(Hash) || item.is_a?(Lazy)
        return if pattern.nil?
        unless pattern.is_a?(String)
          raise UsageError, "#{path}: allowed_pattern must be a String, got #{pattern.inspect}"
        end

        begin
          regexp = Regexp.new(pattern)
        rescue RegexpError => e
          raise UsageError, "#{path}: allowed_pattern is not a regular expression: #{e.message}"
        end
        return if item.is_a?(String) && regexp.match?(item)

        raise UsageError, "#{path}: The supplied value (#{item}) does not match the specified allowedPattern (#{pattern})"
      end

      # The CDK's StringListParameter check (parameter.ts:870-872).
      def assert_no_comma(item)
        return unless item.is_a?(String) && item.include?(",")

        raise UsageError, "#{path}: Values of a StringList SSM Parameter cannot contain the ',' character. " \
          "Use a string parameter instead."
      end

      # The comma-joined value of a string list, as the CDK writes it
      # (parameter.ts:890); a literal list resolves to the joined string, as
      # the CDK's resolved template shows it.
      def rendered_value
        return Fn.join(",", @values) if @type == :string_list

        @values.first
      end
    end
  end
end
