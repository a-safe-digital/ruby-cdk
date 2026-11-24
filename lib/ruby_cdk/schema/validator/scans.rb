# frozen_string_literal: true

require_relative "../../schema"
require_relative "../normalizer"
require_relative "template"
require_relative "walk"

module RubyCdk
  module Validation
    # The scans more than one rule of the schema needs: every resource, every key the
    # normalizer could not resolve, every leaf value, and what kind of value a kind of
    # property takes. Nothing here decides anything: the rules do.
    module Scans
      # The resources of a template, with what the model knows of them.
      module Resources
        module_function

        # Yields [ name, body, path ] for every resource.
        def each(context)
          Template.resources(context.template).each { |name, body| yield name, body, [ "Resources", name.to_s ] }
        end

        # Yields [ name, body, path, type, properties ] for every resource whose type the
        # model knows and whose Properties is an object. path is that of the Properties.
        #
        def typed(context)
          each(context) do |name, body, path|
            type = Schema.type(Template.resource_type(body).to_s)
            properties = body["Properties"]
            next unless type && properties.is_a?(Hash)

            yield name, body, path + [ "Properties" ], type, properties
          end
        end
      end

      # Every key under a typed resource's properties that is not a property's exact name:
      # the one scan rules V3 and V4 share.
      module Keys
        module_function

        # Yields [ key, outcome, names, segments, owner ]: the key as written, what the
        # normalizer made of it (:unique, :none or :ambiguous), every property of what it
        # sits on, where it is, and what it sits on.
        def unresolved(context)
          Resources.typed(context) do |_name, _body, path, type, properties|
            next if type.additional_properties?

            SchemaWalk.each_node(type, properties, path) do |walk_type, node, hash, at|
              hash.each_key do |key|
                outcome, = Normalizer.resolve(key.to_s, node)
                next if outcome == :exact

                yield key.to_s, outcome, node.properties.keys, at + [ key.to_s ], Template.node_name(walk_type, node)
              end
            end
          end
        end
      end

      # Every value the model gives a kind: the value itself, then each literal element of
      # a list or a map whose elements have a scalar kind. The one walk rules V6, V7, V17,
      # V18 and V19 share.
      module Leaves
        SCALARS = %i[string integer long double boolean timestamp].freeze

        module_function

        # Yields [ type, node, property, kind, value, segments ]
        def each(context)
          Resources.typed(context) do |_name, _body, path, type, properties|
            SchemaWalk.each_value(type, properties, path) do |walk_type, node, property, value, at|
              yield walk_type, node, property, property.kind, value, at
              next unless SCALARS.include?(property.item_kind)

              if property.kind == :list && value.is_a?(Array)
                value.each_with_index do |item, index|
                  yield walk_type, node, property, property.item_kind, item, at + [ "[#{index}]" ] if Template.literal?(item)
                end
              elsif property.kind == :map && value.is_a?(Hash)
                value.each do |key, item|
                  yield walk_type, node, property, property.item_kind, item, at + [ key.to_s ] if Template.literal?(item)
                end
              end
            end
          end
        end
      end

      # What kind of value each kind of property takes (V6), and what is written in its
      # place wrongly: a number or a boolean in quotes (V17).
      module Kind
        WHOLE = /\A\s*-?\d+\s*\z/
        DECIMAL = /\A\s*-?\d+(\.\d+)?([eE][-+]?\d+)?\s*\z/
        ARTICLES = { string: "a string", integer: "a whole number", long: "a whole number", double: "a number", boolean: "a boolean",
                     timestamp: "a timestamp", json: "an object", nested: "an object", map: "an object", list: "a list" }.freeze
        HINTS = { string: "write it in quotes", integer: "write it without quotes and without decimals",
                  long: "write it without quotes and without decimals", double: "write it without quotes",
                  boolean: "write true or false, without quotes", timestamp: 'write an ISO 8601 string, as "2026-01-01T00:00:00Z"',
                  json: "write a Hash", nested: "write a Hash", map: "write a Hash" }.freeze

        module_function

        # :ok; :wrong for a value of another kind (V6); :string_for_number or
        # :string_for_boolean for the right value in quotes (V17).
        #
        # A number or a boolean where a string belongs is :ok, as the CDK takes it
        # (cloudformation-include/test/valid-templates.test.ts: "accepts numbers for
        # properties with type string", "accepts booleans for properties with type
        # string"), and CloudFormation does too.
        def check(kind, value)
          case kind
          when :string
            scalar?(value) ? :ok : :wrong
          when :integer, :long
            value.is_a?(Integer) ? :ok : value.is_a?(String) && value.match?(WHOLE) ? :string_for_number : :wrong
          when :double
            value.is_a?(Numeric) ? :ok : value.is_a?(String) && value.match?(DECIMAL) ? :string_for_number : :wrong
          when :boolean
            value == true || value == false ? :ok : value == "true" || value == "false" ? :string_for_boolean : :wrong
          when :timestamp
            value.is_a?(String) ? :ok : :wrong
          when :json
            value.is_a?(Hash) || value.is_a?(Array) ? :ok : :wrong
          when :nested, :map
            value.is_a?(Hash) ? :ok : :wrong
          else
            :ok
          end
        end

        def scalar?(value)
          value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
        end

        def article(kind)
          ARTICLES[kind]
        end

        def hint(kind)
          HINTS[kind]
        end
      end
    end
  end
end
