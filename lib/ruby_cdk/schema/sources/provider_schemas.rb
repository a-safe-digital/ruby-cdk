# frozen_string_literal: true

require "json"
require "zlib"
require "zip"
require_relative "../../errors"

module RubyCdk
  module Schema
    module Sources
      # The provider schema zip of one region, read straight from the archive in memory:
      # nothing is extracted to disk.
      module ProviderSchemas
        SCHEMA_FILE = /\A[A-Za-z0-9-]+\.json\z/
        GZIP_MAGIC = "\x1f\x8b".b

        class << self
          # bytes: the zip as downloaded, which may come wrapped in a transfer gzip. Returns
          # { "AWS::Lambda::Function" => schema, ... }, keyed by each schema's own typeName.
          def parse(bytes)
            bytes = Zlib.gunzip(bytes) if bytes.start_with?(GZIP_MAGIC)
            schemas = {}
            zip = Zip::File.open_buffer(bytes)
            begin
              zip.entries.each do |entry|
                next unless entry.file?

                name = entry.name
                raise RubyCdk::Error, "the provider schema zip holds #{name.inspect}, which is not a schema file" unless name.match?(SCHEMA_FILE)

                schema = JSON.parse(entry.get_input_stream { |io| io.read })
                type_name = schema.is_a?(Hash) ? schema["typeName"] : nil
                raise RubyCdk::Error, "#{name} in the provider schema zip has no typeName" unless type_name.is_a?(String)
                raise RubyCdk::Error, "the provider schema zip describes #{type_name} twice" if schemas.key?(type_name)

                schemas[type_name] = schema
              end
            ensure
              zip.close
            end
            schemas
          end
        end
      end
    end
  end
end
