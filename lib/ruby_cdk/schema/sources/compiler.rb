# frozen_string_literal: true

require_relative "../../errors"
require_relative "provider_type"
require_relative "specification_type"

module RubyCdk
  module Schema
    module Sources
      # What a call to Compiler yields: the model as a Hash of plain values, ready to be
      # serialized, and the counts META.json records.
      Compiled = Data.define(:model, :counts)

      # Compiles both sources into the model: every type the provider schemas describe, with
      # what the resource specification adds, and every type only the specification has.
      class Compiler
        def initialize(provider_schemas:, specification:)
          @provider_schemas = provider_schemas
          @specification = specification
        end

        # region goes into the model; it is what the two sources were downloaded for.
        def call(region:)
          types = @provider_schemas.to_h do |name, schema|
            [ name, ProviderType.new(schema, @specification).call ]
          end
          (@specification.resource_types.keys - @provider_schemas.keys).each do |name|
            types[name] = SpecificationType.new(@specification, name).call
          end

          model = {
            "format" => RubyCdk::Schema::MODEL_FORMAT,
            "region" => region,
            "specification_version" => @specification.version,
            "types" => types
          }
          Compiled.new(model:, counts: counts(types))
        end

        private

        def counts(types)
          provider = @provider_schemas.keys
          specification = @specification.resource_types.keys
          {
            "types" => types.size,
            "provider_schemas" => provider.size,
            "resource_specification" => specification.size,
            "only_provider_schemas" => (provider - specification).size,
            "only_resource_specification" => (specification - provider).size
          }
        end
      end
    end
  end
end
