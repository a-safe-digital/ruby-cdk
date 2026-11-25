# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "grant"

module RubyCdk
  module DynamoDB
    # A DynamoDB table: the port of the CDK's Table (aws-dynamodb/lib/table.ts),
    # read at commit c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   RubyCdk::DynamoDB::Table.new(stack, "Table",
    #     partition_key: { name: "id", type: :string },
    #     sort_key: { name: "sk", type: :number })
    #
    # Defaults, and where they differ from the CDK (architecture section 7
    # wins; the rows are in section 21):
    #
    #   - Billing is on demand: BillingMode PAY_PER_REQUEST, the plan's default
    #     for a small project, where the CDK's default is provisioned with 5
    #     read and 5 write units (table.ts:1347). billing: :provisioned writes
    #     ProvisionedThroughput with the capacities given, 5 and 5 when none
    #     are.
    #   - Point-in-time recovery is on: PointInTimeRecoverySpecification with
    #     PointInTimeRecoveryEnabled true, the nag rule for a table without it
    #     being a medium. The CDK writes no specification at all, which leaves
    #     recovery off. point_in_time_recovery: false writes the specification
    #     with false, as the CDK's pointInTimeRecovery: false does.
    #   - The table is a retained type (architecture section 7), which the
    #     synthesis gives every AWS::DynamoDB::Table.
    #
    # Key attributes take their type as a Symbol (:string, :number, :binary)
    # or as DynamoDB's own letter ("S", "N", "B").
    #
    # The grants are the CDK's (aws-dynamodb/lib/table-grants.ts and perms.ts,
    # at the same commit): grant_read_data is the read actions and
    # DescribeTable, grant_read_write_data adds the write ones, each one
    # statement on the table's ARN - the CDK grants the same set as two
    # statements that its policy document minimizes into one, and this tool
    # writes the one. grant_full_access is dynamodb:*, and grant takes any
    # actions given.
    class Table < Construct
      # The CDK's data read actions, then DescribeTable, in the order its
      # minimized statement carries (table-grants.ts, readData; its test).
      READ_DATA_ACTIONS = [
        "dynamodb:BatchGetItem", "dynamodb:GetRecords", "dynamodb:GetShardIterator",
        "dynamodb:Query", "dynamodb:GetItem", "dynamodb:Scan", "dynamodb:ConditionCheckItem",
        "dynamodb:DescribeTable"
      ].freeze

      # readWriteData: the read actions, then the write ones, then
      # DescribeTable, in the CDK's order.
      READ_WRITE_DATA_ACTIONS = [
        "dynamodb:BatchGetItem", "dynamodb:GetRecords", "dynamodb:GetShardIterator",
        "dynamodb:Query", "dynamodb:GetItem", "dynamodb:Scan", "dynamodb:ConditionCheckItem",
        "dynamodb:BatchWriteItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem",
        "dynamodb:DescribeTable"
      ].freeze

      # The CDK's AttributeType names.
      ATTRIBUTE_TYPES = { string: "S", number: "N", binary: "B" }.freeze

      # The CDK's default provisioned capacities (table.ts:1372).
      DEFAULT_CAPACITY = 5

      attr_reader :partition_key, :sort_key, :billing

      def initialize(scope, id, partition_key:, sort_key: nil, table_name: nil, billing: :on_demand,
        read_capacity: nil, write_capacity: nil, point_in_time_recovery: true)
        super(scope, id)
        @partition_key = attribute(partition_key, "partition_key")
        @sort_key = sort_key && attribute(sort_key, "sort_key")
        @table_name = table_name.nil? || table_name.is_a?(String) && !table_name.empty? ? table_name :
          raise(UsageError, "#{path}: table_name must be a non-empty String, got #{table_name.inspect}")
        @billing = billing == :on_demand || billing == :provisioned ? billing :
          raise(UsageError, "#{path}: billing takes :on_demand or :provisioned, got #{billing.inspect}")
        @pitr = point_in_time_recovery == true || point_in_time_recovery == false ? point_in_time_recovery :
          raise(UsageError, "#{path}: point_in_time_recovery takes true or false, got #{point_in_time_recovery.inspect}")

        # Grown with pushes rather than a literal of one, so that the key types
        # stay plain Strings for the checker.
        schema = []
        schema << { "AttributeName" => @partition_key[:name], "KeyType" => "HASH" }
        definitions = []
        definitions << { "AttributeName" => @partition_key[:name], "AttributeType" => @partition_key[:type] }
        if @sort_key
          schema << { "AttributeName" => @sort_key[:name], "KeyType" => "RANGE" }
          definitions << { "AttributeName" => @sort_key[:name], "AttributeType" => @sort_key[:type] }
        end

        @resource = resource("Resource", "AWS::DynamoDB::Table",
          TableName: @table_name,
          AttributeDefinitions: definitions,
          KeySchema: schema,
          BillingMode: @billing == :on_demand ? "PAY_PER_REQUEST" : nil,
          ProvisionedThroughput: @billing == :provisioned ?
            {
              "ReadCapacityUnits" => read_capacity || DEFAULT_CAPACITY,
              "WriteCapacityUnits" => write_capacity || DEFAULT_CAPACITY
            } : nil,
          PointInTimeRecoverySpecification: { "PointInTimeRecoveryEnabled" => @pitr })
      end

      # The logical ID of the AWS::DynamoDB::Table under this construct, so
      # that the table can sit in another resource's depends_on:.
      def logical_id
        @resource.logical_id
      end

      # The table's ARN.
      def arn
        Fn.get_att(@resource, "Arn")
      end

      # The table's name: the one given, or the Ref of the resource.
      def table_name
        @table_name || Fn.ref(@resource)
      end

      # Permits all data read operations from this table: the CDK's
      # grantReadData (table-grants.ts, readData, its minimized statement).
      def grant_read_data(principal)
        Constructs::Grant.add_to_principal(principal, READ_DATA_ACTIONS, [ arn ])
      end

      # Permits all data read and write operations: the CDK's
      # grantReadWriteData (table-grants.ts, readWriteData).
      def grant_read_write_data(principal)
        Constructs::Grant.add_to_principal(principal, READ_WRITE_DATA_ACTIONS, [ arn ])
      end

      # Permits every operation on the table: the CDK's grantFullAccess.
      def grant_full_access(principal)
        Constructs::Grant.add_to_principal(principal, [ "dynamodb:*" ], [ arn ])
      end

      # Grants the actions given, as the CDK's grant does (table-grants.ts,
      # actions).
      def grant(principal, *actions)
        Constructs::Grant.add_to_principal(principal, actions, [ arn ])
      end

      private

      # { name:, type: } with the type as a Symbol or DynamoDB's letter.
      def attribute(key, what)
        unless key.is_a?(Hash) && key[:name].is_a?(String) && !key[:name].empty?
          raise UsageError, "#{path}: #{what} takes { name:, type: }, got #{key.inspect}"
        end

        type = ATTRIBUTE_TYPES[key[:type]] || key[:type]
        unless type.is_a?(String) && %w[S N B].include?(type)
          raise UsageError, "#{path}: #{what}'s type takes :string, :number, :binary, \"S\", \"N\" or \"B\", got #{key[:type].inspect}"
        end

        { name: key[:name], type: type }
      end
    end
  end
end
