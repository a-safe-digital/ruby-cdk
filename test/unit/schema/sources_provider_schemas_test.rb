# frozen_string_literal: true

require "test_helper"
require_relative "../../support/schema_fixtures"

# The provider schema zip, read in memory.
class SourcesProviderSchemasTest < Minitest::Test
  ProviderSchemas = RubyCdk::Schema::Sources::ProviderSchemas

  def test_every_schema_is_read_under_its_type_name
    schemas = ProviderSchemas.parse(SchemaFixtures.provider_bytes)

    assert_equal %w[AWS::Demo::Unlisted AWS::Demo::Widget], schemas.keys.sort
    assert_equal SchemaFixtures.provider_schemas, schemas
  end

  def test_a_folder_entry_is_skipped
    widget = JSON.generate(SchemaFixtures.provider_schemas.fetch("AWS::Demo::Widget"))

    assert_equal %w[AWS::Demo::Widget], ProviderSchemas.parse(SchemaFixtures.zip_with_a_folder("aws-demo-widget.json", widget)).keys
  end

  def test_an_entry_that_is_not_a_schema_fails_loudly
    error = assert_raises(RubyCdk::Error) { ProviderSchemas.parse(SchemaFixtures.zip([ "README.txt", "hello" ])) }

    assert_match(/README\.txt.*not a schema file/, error.message)
  end

  def test_an_entry_inside_a_folder_fails_loudly
    error = assert_raises(RubyCdk::Error) { ProviderSchemas.parse(SchemaFixtures.zip([ "schemas/aws-demo-widget.json", "{}" ])) }

    assert_match(%r{schemas/aws-demo-widget\.json.*not a schema file}, error.message)
  end

  def test_a_schema_without_a_type_name_fails_loudly
    error = assert_raises(RubyCdk::Error) { ProviderSchemas.parse(SchemaFixtures.zip([ "aws-demo-nameless.json", '{"type":"object"}' ])) }

    assert_match(/aws-demo-nameless\.json in the provider schema zip has no typeName/, error.message)
  end

  def test_a_type_described_twice_fails_loudly
    twice = '{"typeName":"AWS::Demo::Twice","properties":{}}'

    error = assert_raises(RubyCdk::Error) { ProviderSchemas.parse(SchemaFixtures.zip([ "a.json", twice ], [ "b.json", twice ])) }

    assert_match(/describes AWS::Demo::Twice twice/, error.message)
  end

  def test_an_empty_zip_holds_no_schema
    assert_equal({}, ProviderSchemas.parse(SchemaFixtures.zip))
  end

  def test_a_zip_wrapped_in_a_transfer_gzip_is_unwrapped
    assert_equal %w[AWS::Demo::Unlisted AWS::Demo::Widget], ProviderSchemas.parse(Zlib.gzip(SchemaFixtures.provider_bytes)).keys.sort
  end

  def test_something_that_is_not_a_zip_is_refused
    assert_raises(Zip::Error) { ProviderSchemas.parse("this is not a zip") }
  end
end
