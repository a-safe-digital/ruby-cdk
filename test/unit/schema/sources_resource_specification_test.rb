# frozen_string_literal: true

require "test_helper"
require_relative "../../support/schema_fixtures"

# The resource specification, parsed, and the lookups the compilers make in it.
class SourcesResourceSpecificationTest < Minitest::Test
  Specification = RubyCdk::Schema::Sources::ResourceSpecification

  def setup
    @specification = Specification.parse(SchemaFixtures.specification_bytes)
  end

  def test_the_gzip_aws_serves_is_parsed
    assert_equal "1.2.3", @specification.version
    assert_equal %w[AWS::Demo::OnlySpec AWS::Demo::Open AWS::Demo::Widget], @specification.resource_types.keys.sort
    assert_equal "Immutable", @specification.resource_type("AWS::Demo::Widget").dig("Properties", "Name", "UpdateType")
    assert_nil @specification.resource_type("AWS::Demo::Unlisted")
  end

  def test_plain_json_is_read_as_well
    assert_equal "1.2.3", Specification.parse(JSON.generate(SchemaFixtures.specification)).version
  end

  def test_what_is_not_a_specification_fails_loudly
    assert_match(/not JSON/, assert_raises(RubyCdk::Error) { Specification.parse("nope") }.message)
    assert_match(/not JSON/, assert_raises(RubyCdk::Error) { Specification.parse(Zlib.gzip("nope")) }.message)
    assert_match(/not one JSON object/, assert_raises(RubyCdk::Error) { Specification.parse("[1, 2]") }.message)

    document = SchemaFixtures.specification
    document.delete("ResourceSpecificationVersion")
    assert_match(/lacks ResourceSpecificationVersion/, assert_raises(RubyCdk::Error) { Specification.parse(JSON.generate(document)) }.message)
  end

  def test_a_property_type_is_found_relative_to_its_resource_type_or_among_the_shared_ones
    assert_equal %w[ApiKey Retries Window], @specification.property_type("AWS::Demo::Widget", "Settings")["Properties"].keys
    assert_equal %w[Key Value], @specification.property_type("AWS::Demo::Widget", "Tag")["Properties"].keys
    assert_nil @specification.property_type("AWS::Demo::Widget", "Nowhere")
  end

  def test_what_a_property_holds
    properties = @specification.resource_type("AWS::Demo::Widget")["Properties"]

    assert_equal %w[ApiKey Retries Window], @specification.properties("AWS::Demo::Widget", properties["Settings"]).keys       # a nested type
    assert_equal %w[Region Priority], @specification.properties("AWS::Demo::Widget", properties["Replicas"]).keys          # a list of a nested type
    assert_equal %w[Region Priority], @specification.properties("AWS::Demo::Widget", { "Type" => "Map", "ItemType" => "Replica" }).keys
    assert_nil @specification.properties("AWS::Demo::Widget", properties["Sizes"])      # a list of primitives
    assert_nil @specification.properties("AWS::Demo::Widget", properties["Name"])       # a primitive
    assert_nil @specification.properties("AWS::Demo::Widget", properties["Level"])      # a name the specification does not define

    admins = @specification.resource_type("AWS::Demo::OnlySpec")["Properties"]["Admins"]
    assert_equal %w[Id Rank], @specification.properties("AWS::Demo::OnlySpec", admins).keys                            # a property type that is itself a list
  end
end
