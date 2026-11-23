# frozen_string_literal: true

require "test_helper"
require_relative "../../support/schema_fixtures"

# TypeSchema, Definition and PropertySchema: on the committed model for real AWS types, and
# on a model built from the fixtures, where every path can be pinned.
class TypeSchemaTest < Minitest::Test
  Schema = RubyCdk::Schema
  WIDGET = "AWS::Demo::Widget"

  def lambda_function
    Schema.type("AWS::Lambda::Function")
  end

  def widget
    @widget ||= SchemaFixtures.model.type(WIDGET)
  end

  # --- the committed model

  def test_lambda_function_comes_from_the_provider_schema
    fn = lambda_function

    assert_equal :provider, fn.source
    assert_equal "AWS::Lambda::Function", fn.name
    assert_equal "https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-lambda-function.html", fn.documentation_url
    assert_equal %w[Code Role], fn.required
    assert_includes fn.create_only, "FunctionName"
    assert_includes fn.create_only, "PackageType"
    %w[Arn SnapStartResponse SnapStartResponse.ApplyOn SnapStartResponse.OptimizationStatus].each { |path| assert_includes fn.read_only, path }
    refute fn.additional_properties?
  end

  def test_lambda_function_properties_have_their_kinds
    fn = lambda_function

    assert_equal [ :string, nil, nil ], [fn.properties["Runtime"].kind, fn.properties["Runtime"].item_kind, fn.properties["Runtime"].definition]
    assert_equal :integer, fn.properties["MemorySize"].kind
    assert_equal :boolean, fn.properties["PublishToLatestPublished"].kind
    assert_equal [ :nested, nil, "Code" ], [fn.properties["Code"].kind, fn.properties["Code"].item_kind, fn.properties["Code"].definition]
    assert_equal [ :list, :string, nil ], [fn.properties["Layers"].kind, fn.properties["Layers"].item_kind, fn.properties["Layers"].definition]
    assert_equal [ :list, :nested, "Tag" ], [fn.properties["Tags"].kind, fn.properties["Tags"].item_kind, fn.properties["Tags"].definition]
    assert fn.properties["Code"].required
    refute fn.properties["Runtime"].required
    assert_equal "Runtime", fn.properties["Runtime"].name
  end

  def test_lambda_function_allowed_values_and_patterns
    fn = lambda_function

    assert_equal %w[Image Zip], fn.properties["PackageType"].allowed_values
    assert_equal :immutable, fn.properties["PackageType"].update_behaviour
    assert_equal :immutable, fn.properties["FunctionName"].update_behaviour
    # The enum sits on the list's elements in the source; the property carries it for them.
    assert_equal %w[x86_64 arm64], fn.properties["Architectures"].allowed_values
    assert_equal true, fn.properties["Architectures"].unique_items
    assert_equal %w[Active PassThrough], fn.definitions["TracingConfig"].properties["Mode"].allowed_values
    assert_equal "^[^\\s]+$", fn.properties["Handler"].pattern
    assert_nil fn.properties["Runtime"].allowed_values
    assert_nil fn.properties["Runtime"].pattern
  end

  def test_lambda_function_nested_definitions
    fn = lambda_function

    %w[S3Bucket S3Key ZipFile].each { |name| assert_includes fn.definitions["Code"].properties, name }
    assert_equal :string, fn.definitions["Code"].properties["S3Bucket"].kind
    assert_equal "S3Bucket", fn.definitions["Code"].properties["S3Bucket"].name
    assert_equal %w[Key], fn.definitions["Tag"].required       # what the provider schema requires of a tag
    assert_equal fn.definitions.keys, fn.definitions.keys.sort
  end

  def test_dynamodb_table
    table = Schema.type("AWS::DynamoDB::Table")
    key_schema = table.properties["KeySchema"]

    assert_equal :provider, table.source
    assert_equal %w[KeySchema], table.required
    assert_equal [ :list, :nested, "KeySchema", true, :immutable, true ],
      [key_schema.kind, key_schema.item_kind, key_schema.definition, key_schema.required, key_schema.update_behaviour, key_schema.unique_items]
    assert_equal %w[AttributeName KeyType], table.definitions["KeySchema"].required.sort
    assert_equal :string, table.definitions["KeySchema"].properties["KeyType"].kind
    assert_equal :immutable, table.properties["TableName"].update_behaviour
    assert_includes table.create_only, "TableName"
    assert_includes table.read_only, "Arn"
    assert_equal :string, table.properties["BillingMode"].kind
  end

  def test_s3_bucket
    bucket = Schema.type("AWS::S3::Bucket")

    assert_equal :immutable, bucket.properties["BucketName"].update_behaviour
    assert_equal %w[AuthenticatedRead AwsExecRead BucketOwnerFullControl BucketOwnerRead LogDeliveryWrite Private PublicRead PublicReadWrite], bucket.properties["AccessControl"].allowed_values
    assert_equal [ :nested, "VersioningConfiguration" ], [bucket.properties["VersioningConfiguration"].kind, bucket.properties["VersioningConfiguration"].definition]
    assert_equal %w[aws:kms AES256 aws:kms:dsse], bucket.definitions["ServerSideEncryptionByDefault"].properties["SSEAlgorithm"].allowed_values
    assert_includes bucket.read_only, "Arn"
    assert_includes bucket.read_only, "WebsiteURL"
    assert bucket.read_only.any? { |path| path.count(".") >= 2 }, "read-only paths go as deep as the schema: #{bucket.read_only.first(4).inspect}"
  end

  def test_an_integer_enum_and_a_type_that_takes_any_property
    retention = Schema.type("AWS::Logs::LogGroup").properties["RetentionInDays"]

    assert_equal :integer, retention.kind
    assert_equal [1, 3, 5, 7], retention.allowed_values.first(4)
    assert retention.allowed_values.all?(Integer)
    assert Schema.type("AWS::CloudFormation::CustomResource").additional_properties?
    refute Schema.type("AWS::Logs::LogGroup").additional_properties?
  end

  def test_a_type_that_exists_only_in_the_specification
    session = Schema.type("AWS::Athena::Session")

    assert_equal :specification, session.source
    assert_equal "https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-athena-session.html", session.documentation_url
    assert_equal %w[EngineConfiguration WorkGroup], session.required
    assert_equal %w[EngineConfiguration ExecutionRole WorkGroup], session.create_only
    assert_equal [ :nested, "EngineConfiguration", :immutable, true ],
      [session.properties["EngineConfiguration"].kind, session.properties["EngineConfiguration"].definition, session.properties["EngineConfiguration"].update_behaviour, session.properties["EngineConfiguration"].required]
    assert_equal %w[MaxConcurrentDpus], session.definitions["EngineConfiguration"].required
    spark = session.definitions["EngineConfiguration"].properties["SparkProperties"]
    assert_equal [ :map, :string, :immutable ], [spark.kind, spark.item_kind, spark.update_behaviour]
    assert_includes session.read_only, "EngineConfiguration.SparkProperties"
  end

  def test_update_behaviour_on_real_types
    assert_equal :immutable, lambda_function.update_behaviour("FunctionName")
    assert_equal :mutable, lambda_function.update_behaviour("Tags.0.Key")
    assert_equal :mutable, lambda_function.update_behaviour([:Tags, 0, :Key])
    assert_equal :unknown, lambda_function.update_behaviour("Arn")
    assert_equal :unknown, lambda_function.update_behaviour("SnapStartResponse.ApplyOn")
    assert_equal :unknown, lambda_function.update_behaviour("Runtime.Nope")
    assert_equal :unknown, lambda_function.update_behaviour("")
    assert_equal :immutable, Schema.update_type("AWS::DynamoDB::Table", "KeySchema.0.KeyType")
  end

  # --- a model built from the fixtures

  def test_the_update_behaviour_of_a_path_is_the_costliest_along_it
    assert_equal :immutable, widget.update_behaviour("Name")
    assert_equal :mutable, widget.update_behaviour("Settings.Retries")
    assert_equal :conditional, widget.update_behaviour("Settings.Window")
    assert_equal :immutable, widget.update_behaviour("Settings.Window.To")
    assert_equal :conditional, widget.update_behaviour("Settings.Window.From")
    assert_equal :immutable, widget.update_behaviour("Settings.ApiKey")
    assert_equal :conditional, widget.update_behaviour("Status.Code")
    assert_equal :mutable, widget.update_behaviour("Tags.0.Key")
    assert_equal :mutable, widget.update_behaviour([:Tags, 0, :Key])
    assert_equal :mutable, widget.update_behaviour("Zones.3")
    assert_equal :mutable, widget.update_behaviour("Labels.anything")
    assert_equal :mutable, widget.update_behaviour("Requests.any.Required")
    assert_equal :mutable, widget.update_behaviour("Route.S3.Bucket")
  end

  def test_a_path_that_ends_at_a_read_only_property_or_names_nothing_is_unknown
    assert_equal :unknown, widget.update_behaviour("Arn")
    assert_equal :unknown, widget.update_behaviour("Status.Message")
    assert_equal :unknown, widget.update_behaviour("Nope")
    assert_equal :unknown, widget.update_behaviour("Settings.Nope")
    assert_equal :unknown, widget.update_behaviour("Store.Nope")
    assert_equal :unknown, widget.update_behaviour("")
    assert_equal :unknown, widget.update_behaviour([])
    assert_equal :unknown, widget.update_behaviour(nil)
  end

  def test_a_path_deeper_than_the_schema_describes_answers_for_the_last_property_it_named
    assert_equal :immutable, widget.update_behaviour("Name.deeper")
    assert_equal :conditional, widget.update_behaviour("Size.Nope")
    assert_equal :mutable, widget.update_behaviour("Policy.Statement.0.Effect")
  end

  def test_properties_keep_the_source_s_order_and_definitions_are_sorted
    assert_equal %w[Name Arn Size Offset Ratio Enabled CreatedAt Level], widget.properties.keys.first(8)
    assert_equal %w[SpecOnly ImmutableBySpec], widget.properties.keys.last(2)
    assert_equal widget.definitions.keys, widget.definitions.keys.sort
  end

  def test_properties_and_definitions_are_frozen_value_objects
    level = widget.properties["Level"]

    assert_predicate level, :frozen?
    assert_predicate level.allowed_values, :frozen?
    assert_raises(FrozenError) { level.allowed_values << "Medium" }
    assert_raises(FrozenError) { widget.properties["More"] = level }
    assert_raises(FrozenError) { widget.definitions["More"] = widget.definitions["Tag"] }
    assert_equal Schema::PropertySchema.new(name: "Level", kind: :string, item_kind: nil, definition: nil, required: false, update_behaviour: :mutable,
      allowed_values: %w[Low High], pattern: nil, unique_items: nil), level
    assert_equal Schema::PropertySchema.new(name: "Level", kind: :string, item_kind: nil, definition: nil, required: false, update_behaviour: :mutable,
      allowed_values: %w[Low High], pattern: nil, unique_items: nil).hash, level.hash

    tag = widget.definitions["Tag"]
    assert_equal "Tag", tag.name
    assert_equal %w[Key], tag.required
    assert tag.properties["Key"].required
    refute tag.properties["Value"].required
    assert_raises(FrozenError) { tag.properties["More"] = level }
  end

  def test_kinds_and_behaviours_are_the_ones_the_architecture_lists
    assert_equal %i[string integer long double boolean timestamp json list map nested], Schema::KINDS
    assert_equal %i[mutable immutable conditional unknown], Schema::UPDATE_BEHAVIOURS
  end
end
