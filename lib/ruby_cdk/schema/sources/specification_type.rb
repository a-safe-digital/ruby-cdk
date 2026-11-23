# frozen_string_literal: true

require_relative "../../errors"

module RubyCdk
  module Schema
    module Sources
      # Compiles a resource type the resource specification describes, and the odd property
      # of a provider-backed type that only the specification knows.
      #
      # This is how a specification property becomes a kind:
      #
      #   PrimitiveType String, Boolean, Integer, Double, Long
      #                            :string, :boolean, :integer, :double, :long
      #   PrimitiveType Json        :json
      #   Type List, Type Map       :list or :map; the element from PrimitiveItemType, or
      #                            from ItemType, which names a nested property type
      #   Type <name>               :nested, a definition under that name
      #
      # A property type that is itself a list or a map ("AWS::LakeFormation::DataLakeSettings.Admins")
      # is followed to its element. A name the specification does not define is :json.
      # The specification has no allowed values and no patterns, and no timestamps.
      class SpecificationType
        PRIMITIVES = { "String" => :string, "Boolean" => :boolean, "Integer" => :integer, "Json" => :json, "Double" => :double, "Long" => :long, "Timestamp" => :timestamp }.freeze
        CONTAINERS = %w[List Map].freeze
        UPDATES = { "Mutable" => "mutable", "Immutable" => "immutable", "Conditional" => "conditional" }.freeze

        # What the specification adds to a type the provider schema also describes:
        # entries are [name, entry] pairs, definitions the nested types they reach.
        Extra = Data.define(:entries, :definitions)

        def initialize(specification, type_name)
          @specification = specification
          @type_name = type_name
          @definitions = {}
          @queue = []
        end

        # For properties only the specification knows: { "Name" => property, ... }.
        def extra(properties)
          entries = properties.map { |name, property| [name, entry(property)] }
          drain
          Extra.new(entries:, definitions: @definitions)
        end

        # The type as the model stores it.
        def call
          resource = @specification.resource_type(@type_name) or
            raise RubyCdk::Error, "the resource specification does not describe #{@type_name}"
          properties = resource["Properties"] || {}
          entries = properties.map { |name, property| [name, entry(property)] }
          drain

          type = {
            "source" => "specification",
            "documentation_url" => resource["Documentation"]&.sub(%r{\Ahttp://docs\.aws\.amazon\.com/}, "https://docs.aws.amazon.com/"),
            "required" => properties.select { |_, property| property["Required"] }.keys.sort,
            "create_only" => properties.filter_map { |name, property| name if property["UpdateType"] == "Immutable" }.sort,
            "read_only" => resource["Attributes"].is_a?(Hash) ? resource["Attributes"].keys.sort : [],
            "properties" => entries,
            "definitions" => @definitions
          }
          # AWS::CloudFormation::CustomResource: a template may set any property.
          type["additional_properties"] = true if resource["AdditionalProperties"] == true
          type
        end

        private

        # A property's entry. Every property reaches drain with the nested types it names queued.
        def entry(property)
          kind, item, of, unique = describe(property)
          entry = { "kind" => kind.to_s }
          entry["item"] = item.to_s if item
          entry["of"] = of if of
          entry["update"] = UPDATES.fetch(property["UpdateType"]) do
            raise RubyCdk::Error, "#{@type_name}: the specification gives a property the update type #{property["UpdateType"].inspect}, which this version does not know"
          end
          entry["unique"] = unique unless unique.nil?
          entry
        end

        # [kind, element kind, definition, unique items].
        def describe(property)
          if property.key?("PrimitiveType")
            [ primitive(property["PrimitiveType"]), nil, nil, nil ]
          elsif CONTAINERS.include?(property["Type"])
            item, of = element_of(property)
            [ property["Type"] == "List" ? :list : :map, item, of,
              property["Type"] == "List" && !property["DuplicatesAllowed"].nil? ? !property["DuplicatesAllowed"] : nil ]
          elsif property["Type"].is_a?(String)
            nested(property["Type"])
          else
            [ :json, nil, nil, nil ]
          end
        end

        def primitive(name)
          PRIMITIVES[name] or raise RubyCdk::Error, "#{@type_name}: the specification has the primitive type #{name.inspect}, which this version does not know"
        end

        # A property whose Type names a property type.
        def nested(name)
          type = @specification.property_type(@type_name, name)
          return [ :json, nil, nil, nil ] unless type.is_a?(Hash)
          return [ :nested, nil, name, nil ] if reaches(name)

          return [ :json, nil, nil, nil ] unless CONTAINERS.include?(type["Type"])

          item, of = element_of(type)
          [ type["Type"] == "List" ? :list : :map, item, of, nil ]
        end

        # [element kind, definition] of a List or a Map, from PrimitiveItemType or ItemType.
        def element_of(property)
          return [ primitive(property["PrimitiveItemType"]), nil ] if property.key?("PrimitiveItemType")

          name = property["ItemType"]
          return [ :json, nil ] unless name.is_a?(String)

          type = @specification.property_type(@type_name, name)
          return [ :nested, name ] if reaches(name)
          return [ type["Type"] == "List" ? :list : :map, nil ] if type.is_a?(Hash) && CONTAINERS.include?(type["Type"])

          [ :json, nil ]
        end

        # True when the specification defines `name` as a type with named properties, which
        # drain then writes as a definition.
        def reaches(name)
          type = @specification.property_type(@type_name, name)
          return false unless type.is_a?(Hash) && type["Properties"].is_a?(Hash)

          @queue << name unless @queue.include?(name) || @definitions.key?(name)
          true
        end

        # Builds every definition an entry reached, and those they reach.
        def drain
          until @queue.empty?
            name = @queue.shift
            next if @definitions.key?(name)

            type = @specification.property_type(@type_name, name)
            raise RubyCdk::Error, "#{@type_name}: the specification names the property type #{name}, which it does not define" unless type.is_a?(Hash) && type["Properties"].is_a?(Hash)

            properties = type["Properties"]
            @definitions[name] = {
              "required" => properties.select { |_, property| property["Required"] }.keys.sort,
              "properties" => properties.map { |property_name, property| [property_name, entry(property)] }
            }
          end
        end
      end
    end
  end
end
