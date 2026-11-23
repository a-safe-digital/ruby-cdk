# frozen_string_literal: true

require "test_helper"
require_relative "../../support/schema_fixtures"

# The loader: Schema over the committed model, Model over whatever directory it is given.
class SchemaTest < Minitest::Test
  Schema = RubyCdk::Schema
  Fixtures = SchemaFixtures

  # The budget is 50 ms on the development machine (architecture section 18). The assertion
  # leaves room for a machine busy with other work and for a shared CI runner. It still fails
  # for anything several times over the budget, such as parsing the raw sources (1.5 s).
  LOAD_LIMIT_MS = 150

  def test_the_committed_model_is_under_data_spec
    assert_equal "data/spec", Schema.dir.split("/").last(2).join("/")
    assert File.file?(File.join(Schema.dir, Schema::MODEL_FILE)), "#{Schema::MODEL_FILE} is not in #{Schema.dir}"
    assert File.file?(File.join(Schema.dir, Schema::META_FILE)), "#{Schema::META_FILE} is not in #{Schema.dir}"
  end

  def test_lookups
    assert_kind_of Schema::TypeSchema, Schema.type("AWS::Lambda::Function")
    assert_nil Schema.type("AWS::No::Such")
    assert Schema.known_type?("AWS::S3::Bucket")
    refute Schema.known_type?("AWS::No::Such")

    assert_kind_of Array, Schema.types
    assert_equal Schema.types, Schema.types.sort
    assert_equal Schema.meta.dig("counts", "types"), Schema.types.size
    assert_includes Schema.types, "Alexa::ASK::Skill"
  end

  def test_lookups_are_answered_from_memory_after_the_first
    assert_same Schema.type("AWS::Lambda::Function"), Schema.type("AWS::Lambda::Function")
    assert_same Schema.meta, Schema.meta
    assert_same Schema.types, Schema.types
  end

  def test_update_type
    assert_equal :immutable, Schema.update_type("AWS::Lambda::Function", "FunctionName")
    assert_equal :mutable, Schema.update_type("AWS::Lambda::Function", "Tags.0.Key")
    assert_equal :unknown, Schema.update_type("AWS::Lambda::Function", "Nope")
    assert_equal :unknown, Schema.update_type("AWS::No::Such", "Nope")
  end

  def test_schema_version_names_the_specification_and_the_model
    version = Schema.schema_version
    meta = Schema.meta

    assert_equal meta["schema_version"], version
    assert_equal "resource specification #{meta["specification_version"]}, model sha256:#{meta["model_sha256"]}, model format #{Schema::MODEL_FORMAT}", version
    # A source AWS republished with the same content moves its Last-Modified, not this.
    refute_includes version, meta.dig("sources", "provider_schemas", "last_modified")
    assert_same version, Schema.schema_version
  end

  def test_meta_matches_the_model_file
    meta = Schema.meta
    json = Zlib.gunzip(File.binread(File.join(Schema.dir, Schema::MODEL_FILE)))

    assert_equal Digest::SHA256.hexdigest(json), meta.fetch("model_sha256")
    assert_equal meta.fetch("region"), Schema::Model.load(Schema.dir).region
    assert_equal %w[provider_schemas resource_specification], meta.fetch("sources").keys.sort
    meta.fetch("sources").each_value do |source|
      assert source.values_at("url", "last_modified", "sha256").all? { |value| value.is_a?(String) }, "a source records its address, its Last-Modified and its SHA-256"
      assert_match(/\A[0-9a-f]{64}\z/, source.fetch("sha256"))
      assert source.key?("etag"), "a source records its ETag"
    end
    counts = meta.fetch("counts")
    assert_equal counts.fetch("types"), counts.fetch("provider_schemas") + counts.fetch("only_resource_specification")
    assert_equal counts.fetch("types"), counts.fetch("resource_specification") + counts.fetch("only_provider_schemas")
    assert_match(/\A\d+\.\d+\.\d+\z/, meta.fetch("specification_version"))
    assert_equal Schema::MODEL_FORMAT, meta.fetch("model_format")
  end

  def test_loading_the_committed_model_stays_within_the_budget
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    model = Schema::Model.load(Schema.dir)
    loaded = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    model.type("AWS::S3::Bucket")
    built = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    milliseconds = (loaded - started) * 1000
    puts "\nschema: the committed model loads in #{milliseconds.round(1)} ms and a type is built in #{((built - loaded) * 1000).round(2)} ms (budget: 50 ms)"
    assert_operator milliseconds, :<, LOAD_LIMIT_MS, "the model took #{milliseconds.round(1)} ms to load"
  end

  def test_a_model_built_from_the_fixtures_loads
    model = Fixtures.model

    assert_equal "us-east-1", model.region
    assert_equal %w[AWS::Demo::OnlySpec AWS::Demo::Open AWS::Demo::Unlisted AWS::Demo::Widget], model.types
    assert model.known_type?("AWS::Demo::Widget")
    refute model.known_type?("AWS::No::Widget")
    assert_nil model.type("AWS::No::Widget")
    assert_same model.type("AWS::Demo::Widget"), model.type("AWS::Demo::Widget")
    assert_equal :immutable, model.update_type("AWS::Demo::Widget", "Name")
    assert_equal :unknown, model.update_type("AWS::No::Widget", "Name")
    assert_equal "us-east-1", model.meta.fetch("region")
  end

  def test_a_missing_model_is_a_clear_error
    Fixtures.in_a_temporary_directory do |dir|
      error = assert_raises(RubyCdk::Error) { Schema::Model.load(dir) }

      assert_match(%r{#{Regexp.escape(File.join(dir, Schema::MODEL_FILE))}.*the gem is not installed completely}, error.message)
    end
  end

  def test_a_model_that_is_not_a_gzip_of_json_is_a_clear_error
    [ "not a gzip", Zlib.gzip("not json") ].each do |bytes|
      Fixtures.in_a_temporary_directory do |dir|
        File.binwrite(File.join(dir, Schema::MODEL_FILE), bytes)
        File.write(File.join(dir, Schema::META_FILE), "{}")

        error = assert_raises(RubyCdk::Error) { Schema::Model.load(dir) }

        assert_match(/not a gzip of one JSON object/, error.message)
      end
    end
  end

  def test_a_model_of_another_format_is_refused
    Fixtures.in_a_temporary_directory do |dir|
      write_model(dir, { "format" => 99, "types" => {} })

      error = assert_raises(RubyCdk::Error) { Schema::Model.load(dir) }

      assert_match(/has format 99.*reads format #{Schema::MODEL_FORMAT}/, error.message)
    end
  end

  def test_a_model_naming_something_this_version_does_not_know_is_refused
    {
      { "kind" => "quaternion" } => /unknown kind, "quaternion"/,
      { "kind" => "list", "item" => "quaternion" } => /unknown item kind, "quaternion"/,
      { "kind" => "string", "update" => "eventually" } => /unknown update behaviour, "eventually"/
    }.each do |entry, expected|
      Fixtures.in_a_temporary_directory do |dir|
        write_model(dir, { "format" => Schema::MODEL_FORMAT, "types" => { "AWS::Demo::One" => { "source" => "provider", "properties" => [ [ "P", entry ] ] } } })

        error = assert_raises(RubyCdk::Error) { Schema::Model.load(dir).type("AWS::Demo::One") }

        assert_match(expected, error.message)
      end
    end
  end

  def test_a_missing_or_broken_meta_is_a_clear_error
    Fixtures.in_a_temporary_directory do |dir|
      write_model(dir, { "format" => Schema::MODEL_FORMAT, "types" => {} })
      File.delete(File.join(dir, Schema::META_FILE))
      assert_match(/META\.json is missing/, assert_raises(RubyCdk::Error) { Schema::Model.load(dir) }.message)

      File.write(File.join(dir, Schema::META_FILE), "not json")
      assert_match(/META\.json is not JSON/, assert_raises(RubyCdk::Error) { Schema::Model.load(dir) }.message)

      File.write(File.join(dir, Schema::META_FILE), "{}")
      assert_match(/META\.json has no schema_version/, assert_raises(RubyCdk::Error) { Schema::Model.load(dir).schema_version }.message)
    end
  end

  private

  # A model directory holding `document` as the model and "{}" as its meta.
  def write_model(dir, document)
    File.binwrite(File.join(dir, Schema::MODEL_FILE), Zlib.gzip(JSON.generate(document)))
    File.write(File.join(dir, Schema::META_FILE), "{}")
  end
end
