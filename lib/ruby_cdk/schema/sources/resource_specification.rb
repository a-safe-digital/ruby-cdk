# frozen_string_literal: true

require "json"
require "zlib"
require_relative "../../errors"

module RubyCdk
  module Schema
    module Sources
      # The resource specification of one region, parsed, with the lookups the compilers need.
      #
      # Its shape: ResourceTypes and PropertyTypes, and ResourceSpecificationVersion. A
      # property is a primitive (PrimitiveType), a list or a map (Type List or Map, with
      # PrimitiveItemType or ItemType), or a nested property type (Type, named relative to
      # the resource type: "Code" on AWS::Lambda::Function is AWS::Lambda::Function.Code).
      # Tag is the one name every resource type shares.
      class ResourceSpecification
        CONTAINERS = %w[List Map].freeze
        TOP_LEVEL = %w[PropertyTypes ResourceTypes ResourceSpecificationVersion].freeze

        class << self
          # bytes: the gzip as published. Plain JSON is read as well.
          def parse(bytes)
            document = JSON.parse(inflate(bytes))
            raise RubyCdk::Error, "the resource specification is not one JSON object" unless document.is_a?(Hash)

            missing = TOP_LEVEL - document.keys
            raise RubyCdk::Error, "the resource specification lacks #{missing.join(", ")}" if missing.any?

            new(document)
          rescue JSON::ParserError
            raise RubyCdk::Error, "the resource specification is not JSON"
          end

          private

          def inflate(bytes)
            Zlib.gunzip(bytes)
          rescue Zlib::GzipFile::Error
            bytes
          end
        end

        attr_reader :version

        def initialize(document)
          @resource_types = document.fetch("ResourceTypes")
          @property_types = document.fetch("PropertyTypes")
          @version = document.fetch("ResourceSpecificationVersion")
        end

        # { "AWS::Lambda::Function" => { "Documentation" => ..., "Properties" => ..., "Attributes" => ... }, ... }
        def resource_types
          @resource_types
        end

        def resource_type(name)
          @resource_types[name]
        end

        # The property type `name` of a resource type: "AWS::Lambda::Function.Code", or the shared Tag.
        def property_type(resource_type, name)
          @property_types["#{resource_type}.#{name}"] || @property_types[name]
        end

        # The properties of what `property` holds, when the specification describes them
        # with named properties: of its nested type, of its list's elements or of its map's
        # values. nil for a primitive, a list or a map of primitives, or a name it does not know.
        def properties(resource_type, property)
          name = property["ItemType"] || (property["Type"] unless CONTAINERS.include?(property["Type"]))
          return nil unless name.is_a?(String)

          type = property_type(resource_type, name)
          while type.is_a?(Hash) && CONTAINERS.include?(type["Type"])
            item = type["ItemType"]
            type = item.is_a?(String) ? property_type(resource_type, item) : nil
          end
          type.is_a?(Hash) ? type["Properties"] : nil
        end
      end
    end
  end
end
