# frozen_string_literal: true

# Builds the two sources as `rake spec:update` downloads them, from the small fixtures under
# test/fixtures/schema_sources: a zip of provider schemas and a gzip of the resource
# specification, both in memory. No test reaches the network: Sources.update is given a
# `get` that answers from these instead.
require "json"
require "tempfile"
require "zip"
require "zlib"
require "ruby_cdk/schema"
require "ruby_cdk/schema/sources"

module SchemaFixtures
  DIR = File.expand_path("../fixtures/schema_sources", __dir__)

  # The us-east-1 addresses, which is what the fixtures are a stand-in for.
  PROVIDER_URL = RubyCdk::Schema::Sources::Regions.urls("us-east-1")[:provider_schemas]
  SPECIFICATION_URL = RubyCdk::Schema::Sources::Regions.urls("us-east-1")[:resource_specification]

  # The clock every alarm rule is judged against, and a Last-Modified 22 days before it.
  NOW = Time.utc(2026, 11, 23, 12)
  LAST_MODIFIED = Time.utc(2026, 11, 1, 9, 30)

  Download = RubyCdk::Schema::Sources::Download

  module_function

  # A parsed fixture file.
  def read(name)
    JSON.parse(File.read(File.join(DIR, name)))
  end

  # The fixture provider schemas, keyed by typeName.
  def provider_schemas
    %w[aws-demo-widget.json aws-demo-unlisted.json].to_h { |name| schema = read(name); [ schema.fetch("typeName"), schema ] }
  end

  # The fixture resource specification as a Hash.
  def specification
    read("resource_specification.json")
  end

  # A zip in memory holding each [entry name, text] pair.
  def zip(*entries)
    Zip::OutputStream.write_buffer(StringIO.new(+"")) do |out|
      entries.each do |name, text|
        out.put_next_entry(name)
        out.write(text)
      end
    end.string
  end

  # A zip in memory with a folder entry in it, as archives built by some tools have.
  def zip_with_a_folder(name, text, folder = "unused")
    Zip::File.open_buffer(StringIO.new(+""), create: true) do |archive|
      archive.mkdir(folder)
      archive.get_output_stream(name) { |entry| entry.write(text) }
    end.string
  end

  # The fixture provider schemas as the real zip is: one entry per type, named after it.
  def provider_bytes(schemas = provider_schemas.values)
    zip(*schemas.map { |schema| [ "#{schema.fetch("typeName").downcase.gsub("::", "-")}.json", JSON.generate(schema) ] })
  end

  # The resource specification as AWS serves it.
  def specification_bytes(document = specification)
    Zlib.gzip(JSON.generate(document))
  end

  def download(url, body, status: 200, last_modified: LAST_MODIFIED, etag: "\"fixture\"")
    Download.new(url:, status:, body:, last_modified:, etag:)
  end

  # Both downloads, by the key Sources gives them.
  def downloads(zip: provider_bytes, specification: specification_bytes, **options)
    {
      provider_schemas: download(PROVIDER_URL, zip, **options),
      resource_specification: download(SPECIFICATION_URL, specification, **options)
    }
  end

  # A stand-in for Fetcher that answers from the downloads Hash and fails on any other address.
  def get(from)
    by_url = from.values.to_h { |download| [ download.url, download ] }
    ->(url) { by_url.fetch(url) { raise "nothing was prepared for #{url}" } }
  end

  # What `rake spec:update` does, on the fixtures. from is the downloads Hash.
  def update(dir, from = downloads, now: NOW)
    RubyCdk::Schema::Sources.update(region: "us-east-1", dir:, get: get(from), now:)
  end

  # Yields a fresh empty directory, removed afterwards.
  def in_a_temporary_directory
    Dir.mktmpdir("ruby-cdk-schema-") { |dir| yield dir }
  end

  # The model built from the fixtures, loaded with the real loader.
  def model
    in_a_temporary_directory do |dir|
      update(dir)
      RubyCdk::Schema::Model.load(dir)
    end
  end
end
