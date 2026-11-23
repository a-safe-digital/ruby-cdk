# frozen_string_literal: true

require_relative "property_schema"

module RubyCdk
  module Schema
    # A nested property type: what a property of kind :nested holds. Reached by name
    # through TypeSchema#definitions, with the key the property's `definition` gives.
    #
    #   name        the key in TypeSchema#definitions
    #   properties  Hash of name to PropertySchema, in the source's order
    #   required    the properties the nested type lists as required
    Definition = Data.define(:name, :properties, :required)

    # One resource type as the vendored model describes it. Everything here is frozen.
    #
    #   name              "AWS::Lambda::Function"
    #   properties        Hash of name to PropertySchema, in the source's order
    #   definitions       Hash of name to Definition
    #   required          the properties a template must set
    #   create_only       property paths that cannot change after creation: "FunctionName", "Code.S3Bucket"
    #   read_only         property paths only Fn::GetAtt may read: "Arn", "SnapStartResponse.ApplyOn"
    #   documentation_url the page AWS documents the type on, or nil when no source has one
    #   source            :provider when the provider schema described the properties, :specification otherwise
    class TypeSchema
      # How much an update behaviour costs. The behaviour of a path is the costliest along it.
      SEVERITY = { mutable: 0, conditional: 1, immutable: 2 }.freeze

      # An index inside a list, as a segment of a path written as a String.
      INDEX = /\A\d+\z/

      attr_reader :name, :properties, :definitions, :required, :create_only, :read_only, :documentation_url, :source

      def initialize(name:, properties:, definitions:, required:, create_only:, read_only:, documentation_url:, source:, additional_properties: false)
        @name = name
        @properties = properties
        @definitions = definitions
        @required = required
        @create_only = create_only
        @read_only = read_only
        @documentation_url = documentation_url
        @source = source
        @additional_properties = additional_properties
        freeze
      end

      # True when the source lets a template set properties it does not list, as
      # AWS::CloudFormation::CustomResource does.
      def additional_properties?
        @additional_properties
      end

      # The update behaviour of a property path: :mutable, :immutable, :conditional,
      # or :unknown when the path does not name a property of this type, or ends at a
      # read-only one, which nothing updates.
      #
      # The answer is the costliest behaviour from the top-level property down to the
      # path's end, because changing a property inside an immutable one replaces the
      # resource as surely as changing the immutable one. "KeySchema[0].AttributeName"
      # is immutable although AttributeName alone is mutable.
      #
      # path is a dotted String ("Code.S3Bucket") or an Array of segments, where an
      # Integer indexes a list: [:code, 0, "S3Bucket"]. A path that goes deeper than
      # the schema describes, into a :json value or past a scalar, answers with the
      # behaviour of the last property it named.
      def update_behaviour(path)
        behaviour = :unknown
        node = self
        skipping = nil

        segments_of(path).each do |segment|
          if skipping == :key || (skipping == :index && segment.match?(INDEX))
            skipping = nil
            next
          end
          skipping = nil

          property = node.properties[segment] or return :unknown
          return :unknown if property.update_behaviour == :unknown

          behaviour = SEVERITY.key([ SEVERITY.fetch(behaviour, -1), SEVERITY.fetch(property.update_behaviour) ].max)
          nested = property.item_kind == :nested || property.kind == :nested
          return behaviour unless nested

          node = definitions[property.definition] or return behaviour
          skipping = :index if property.kind == :list
          skipping = :key if property.kind == :map
        end
        behaviour
      end

      private

      def segments_of(path)
        case path
        when String then path.split(".")
        when Array then path.map(&:to_s)
        else Array(path.to_s)
        end
      end
    end
  end
end
