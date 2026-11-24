# frozen_string_literal: true

require_relative "../../errors"
require_relative "descriptor"
require_relative "specification_type"

module RubyCdk
  module Schema
    module Sources
      # Compiles one resource type out of its provider schema, then merges in what the
      # resource specification adds: the update behaviour of every property, and the odd
      # property only it knows.
      #
      # The provider schema is a JSON Schema with CloudFormation's extensions. This is how
      # a node becomes a kind:
      #
      #   $ref                      resolved to its definition. A definition can be anything,
      #                             a string with a pattern included, so it decides the kind.
      #                             When a property and the definition it points to disagree
      #                             on `type`, the definition wins.
      #   type string               :string, or :timestamp with format date-time
      #   type integer              :integer, or :long with format int64
      #   type number               :double
      #   type boolean              :boolean
      #   type [..] (a union)       :json: every alternative is accepted and none is enforced
      #   type array                :list; the element from `items`, its duplicates rule from uniqueItems
      #   patternProperties         :map of what the patterns describe
      #   properties, or oneOf/anyOf of objects with properties
      #                             :nested, with a definition that lists every property the
      #                             node and its alternatives name
      #   any other object, an empty schema, a mix of an object with a scalar, a list or a map
      #                             :json
      #
      # A definition keeps the name the provider gave it. An object defined inline, without
      # a name, takes the name of the property that holds it, under the one that holds that:
      # "RecoveryPointSelection.DateRange".
      #
      # Allowed values and patterns come from the node, from the definition it points to,
      # and from a list's or a map's elements. Across oneOf and anyOf they survive only when
      # every alternative states the same closed list, because the union of an enum with
      # anything else is open.
      class ProviderType
        # An object with named properties before it becomes a definition. properties maps a
        # name to every node that describes it: the alternatives of a oneOf may each
        # describe the same property. name is the definition the provider gave it, if any.
        Shape = Data.define(:name, :properties, :required)

        # The type itself, in the tables below. A definition is there under its name.
        ROOT = ""

        COMPOSITION = %w[allOf oneOf anyOf].freeze

        # What a path under /properties means for the property it ends at.
        FLAGS = {
          "createOnlyProperties" => :create_only,
          "conditionalCreateOnlyProperties" => :conditional,
          "readOnlyProperties" => :read_only
        }.freeze

        # The numeric kinds, narrowest first.
        NUMERIC = %i[integer long double].freeze

        # How a specification UpdateType is written in the model.
        UPDATES = { "Immutable" => "immutable", "Conditional" => "conditional", "Mutable" => "mutable" }.freeze

        MAX_REFERENCE_HOPS = 20
        MAX_DEPTH = 100

        def initialize(schema, specification)
          @schema = schema
          @specification = specification
          @type_name = schema.fetch("typeName")
          @shapes = {}        # definition name => Shape
          @origins = {}       # definition name => :definition when the provider named it, :inline when this compiler did
          @descriptors = {}   # definition name (ROOT for the type) => { property name => Descriptor }
          @pending = []       # definitions whose properties are not described yet
          @flags = Hash.new { |hash, key| hash[key] = [] }   # [definition name, property name] => the flags on that path
          @specified = {}     # [definition name, property name] => what the specification says about the property
          @extra = nil        # what only the specification knows, as SpecificationType::Extra
        end

        # The type as the model stores it.
        def call
          describe_all
          read_flags
          read_specification
          build
        end

        private

        # --- what every node is

        def describe_all
          register(root_shape, ROOT, :root)
          describe_properties(@pending.shift) until @pending.empty?
        end

        def root_shape
          Shape.new(name: nil, properties: nodes_by_name(@schema["properties"]), required: Array(@schema["required"]))
        end

        def nodes_by_name(properties)
          properties.is_a?(Hash) ? properties.to_h { |name, node| [ name, [ node ] ] } : {}
        end

        def describe_properties(name)
          @descriptors[name] = @shapes.fetch(name).properties.to_h do |property, nodes|
            described = nodes.map { |node| descriptor(node, hint_for(name, property)) }
            [ property, described.reduce { |left, right| or_(left, right) } ]
          end
        end

        def hint_for(name, property)
          name == ROOT ? property : "#{name}.#{property}"
        end

        # Gives an object with named properties its definition: the name the provider gave
        # it, or else the hint, which names the property that holds it. Returns the name of
        # the definition. An object reached again is left alone unless it adds a property
        # or drops a requirement, in which case both are merged and it is described again.
        def register(shape, hint, origin)
          name = shape.name || hint
          existing = @shapes[name]
          if existing.nil?
            @shapes[name] = shape
            @origins[name] = origin
            @pending << name
          elsif !same_shape?(existing, shape)
            if @origins[name] != origin
              raise RubyCdk::Error, "#{@type_name}: the provider schema has a definition called #{name} and an inline object would take the same name"
            end

            merged = or_shape(existing, shape)
            unless same_shape?(existing, merged)
              @shapes[name] = merged
              @descriptors.delete(name)
              @pending << name unless @pending.include?(name)
            end
          end
          name
        end

        def same_shape?(left, right)
          left.properties == right.properties && left.required == right.required
        end

        # The object that satisfies either: every property, and only what both require.
        def or_shape(left, right)
          Shape.new(name: left.name == right.name ? left.name : nil,
            properties: left.properties.merge(right.properties) { |_property, a, b| (a + b).uniq },
            required: left.required & right.required)
        end

        # The object that satisfies both.
        def and_shape(left, right)
          Shape.new(name: left.name == right.name ? left.name : nil,
            properties: left.properties.merge(right.properties) { |_property, a, b| (a + b).uniq },
            required: (left.required + right.required).uniq)
        end

        def descriptor(node, hint, depth = 0)
          to_descriptor(term_of(node, hint, depth), hint)
        end

        def to_descriptor(term, hint)
          case term
          when Shape
            Descriptor.new(kind: :nested, item: nil, of: register(term, hint, term.name ? :definition : :inline), values: nil, pattern: nil, unique: nil)
          when Descriptor
            term
          else
            ANY_VALUE
          end
        end

        # What a node accepts, as one of: :any, when it states nothing; :any_object, an
        # object with no named properties; a Shape; or a Descriptor.
        def term_of(node, hint, depth = 0)
          raise RubyCdk::Error, "#{@type_name}: schema nested deeper than #{MAX_DEPTH} at #{hint}" if depth > MAX_DEPTH
          return :any unless node.is_a?(Hash)

          node, name = dereference(node)
          hint = name || hint
          base = simple_term(node, hint, depth)
          base = base.with(name:) if name && base.is_a?(Shape)

          compositions = COMPOSITION.filter_map { |keyword| [ keyword, node[keyword] ] if node[keyword].is_a?(Array) && node[keyword].any? }
          return base || :any if compositions.empty?

          # allOf is a conjunction; oneOf and anyOf are, for a kind, the same disjunction.
          compositions.reduce(base || :any) do |term, (keyword, alternatives)|
            combined = alternatives.map { |alternative| and_(term, term_of(alternative, hint, depth + 1)) }
            combined.reduce { |left, right| keyword == "allOf" ? and_(left, right) : or_(left, right) }
          end
        end

        def simple_term(node, hint, depth)
          case node["type"]
          when Array then Descriptor.new(kind: :json, item: nil, of: nil, values: node["enum"], pattern: node["pattern"], unique: nil)
          when "array" then list_term(node, hint, depth)
          when "object" then object_term(node, hint, depth)
          when nil then untyped_term(node, hint, depth)
          else scalar_term(node)
          end
        end

        def scalar_term(node)
          kind = case node["type"]
          when "string" then node["format"] == "date-time" ? :timestamp : :string
          when "integer" then node["format"] == "int64" ? :long : :integer
          when "number" then :double
          when "boolean" then :boolean
          end
          return ANY_VALUE unless kind

          Descriptor.new(kind:, item: nil, of: nil, values: node["enum"], pattern: node["pattern"], unique: nil)
        end

        # A node with no `type`, or with annotations only.
        def untyped_term(node, hint, depth)
          if node.key?("patternProperties")
            map_term(node, node["patternProperties"].to_h.values, hint, depth)
          elsif node.key?("properties")
            object_term(node, hint, depth)
          elsif node.key?("items")
            list_term(node, hint, depth)
          elsif node.key?("enum")
            Descriptor.new(kind: kind_of_values(node["enum"]), item: nil, of: nil, values: node["enum"], pattern: node["pattern"], unique: nil)
          elsif node["format"] == "date-time"
            Descriptor.new(kind: :timestamp, item: nil, of: nil, values: nil, pattern: node["pattern"], unique: nil)
          elsif node.key?("pattern")
            Descriptor.new(kind: :string, item: nil, of: nil, values: nil, pattern: node["pattern"], unique: nil)
          end
        end

        def kind_of_values(values)
          return :json unless values.is_a?(Array) && values.any?

          values.all?(String) ? :string : values.all?(Integer) ? :integer : :json
        end

        def list_term(node, hint, depth)
          items = node["items"]
          element = items.is_a?(Hash) ? descriptor(items, hint, depth + 1) : ANY_VALUE
          Descriptor.new(kind: :list, item: element.kind, of: element.kind == :nested ? element.of : nil,
            values: node["enum"] || element.values, pattern: node["pattern"] || element.pattern,
            unique: node["uniqueItems"] == true ? true : node["uniqueItems"] == false ? false : nil)
        end

        def map_term(node, schemas, hint, depth)
          elements = schemas.map { |schema| descriptor(schema, hint, depth + 1) }
          element = elements.first || ANY_VALUE
          return Descriptor.new(kind: :map, item: nil, of: nil, values: nil, pattern: nil, unique: nil) unless elements.all? { |other| other.kind == element.kind && other.of == element.of }

          Descriptor.new(kind: :map, item: element.kind, of: element.of, values: node["enum"] || element.values, pattern: node["pattern"] || element.pattern, unique: nil)
        end

        def object_term(node, hint, depth)
          return map_term(node, [ node["additionalProperties"] ], hint, depth) if node["additionalProperties"].is_a?(Hash)
          return map_term(node, node["patternProperties"].to_h.values, hint, depth) if node.key?("patternProperties")
          return map_term(node, [ node["items"] ], hint, depth) if node.key?("items")   # one schema describes an object's elements under `items`

          properties = node["properties"]
          return :any_object unless properties.is_a?(Hash) && properties.any?

          Shape.new(name: nil, properties: nodes_by_name(properties), required: Array(node["required"]))
        end

        # Follows a chain of $ref to what it describes. Returns the node reached, with the
        # last definition merged in, and the name of the last definition on the way (the one
        # that describes the node), or nil when the chain names none.
        def dereference(node, hops = 0)
          reference = node["$ref"]
          return [ node, nil ] unless reference.is_a?(String)

          raise RubyCdk::Error, "#{@type_name}: a chain of more than #{MAX_REFERENCE_HOPS} references at #{reference}" if hops >= MAX_REFERENCE_HOPS

          target = target_of(reference)
          rest = node.except("$ref")
          reached, deeper = dereference(rest.empty? ? target : merge(target, rest), hops + 1)
          [ reached, deeper || (reference.start_with?("#/definitions/") ? reference.split("/").last : nil) ]
        end

        # A node next to its $ref, with the definition under it: the definition's `type`
        # wins when the two disagree, since it is written once and referenced many times.
        def merge(target, rest)
          merged = target.merge(rest)
          merged["type"] = target["type"] if rest.key?("type") && target["type"] != rest["type"]
          merged
        end

        def target_of(reference)
          path = reference.delete_prefix("#/").split("/")
          target = path.reduce(@schema) { |cursor, part| cursor.is_a?(Hash) ? cursor[part] : nil }
          raise RubyCdk::Error, "#{@type_name}: #{reference} points at nothing" unless target.is_a?(Hash)

          target
        end

        # --- combining terms

        def json?(term)
          term.is_a?(Descriptor) && term.kind == :json
        end

        # The union of what two terms accept. A constraint survives only when both state
        # the same one, so the result is never stricter than the truth, with one exception:
        # a bare object ("type": "object" and nothing else) gives way to the other term.
        # It occurs once in us-east-1 on 2026-11-24, at AWS::DynamoDB::Table KeySchema
        # (a list of KeySchema, or a bare object), and keeping it would make the property
        # :json, where keys are emitted verbatim.
        def or_(left, right)
          return :any if left == :any || right == :any
          return ANY_VALUE if json?(left) || json?(right)

          if left == :any_object || right == :any_object
            other = left == :any_object ? right : left
            return other if other.is_a?(Shape) || (other.is_a?(Descriptor) && other.kind != :json)

            return ANY_VALUE
          end
          return or_shape(left, right) if left.is_a?(Shape) && right.is_a?(Shape)
          return ANY_VALUE unless left.is_a?(Descriptor) && right.is_a?(Descriptor)
          return numeric(left, right, widest: true) unless left.kind == right.kind

          case left.kind
          when :nested
            left.of == right.of ? left : ANY_VALUE
          when :list, :map
            element = union_element(left, right)
            element ? left.with(item: element[0], of: element[1], values: joined(left.values, right.values), pattern: shared_pattern(left.pattern, right.pattern), unique: unique_or(left.unique, right.unique)) : ANY_VALUE
          else
            left.with(values: joined(left.values, right.values), pattern: shared_pattern(left.pattern, right.pattern))
          end
        end

        # What two terms both accept.
        def and_(left, right)
          return right if left == :any || json?(left)
          return left if right == :any || json?(right)

          if left == :any_object || right == :any_object
            other = left == :any_object ? right : left
            return other.is_a?(Shape) || (other.is_a?(Descriptor) && other.kind == :map) ? other : ANY_VALUE
          end
          return and_shape(left, right) if left.is_a?(Shape) && right.is_a?(Shape)
          return ANY_VALUE unless left.is_a?(Descriptor) && right.is_a?(Descriptor)
          return numeric(left, right, widest: false) unless left.kind == right.kind

          case left.kind
          when :nested
            left.of == right.of ? left : ANY_VALUE
          when :list, :map
            element = common_element(left, right)
            element ? left.with(item: element[0], of: element[1], values: shared_values(left.values, right.values), pattern: shared_pattern(left.pattern, right.pattern), unique: unique_and(left.unique, right.unique)) : ANY_VALUE
          else
            left.with(values: shared_values(left.values, right.values), pattern: shared_pattern(left.pattern, right.pattern))
          end
        end

        # Two numeric kinds as one: the widest in a union, the narrowest in an intersection.
        # nil when they cannot both be satisfied, which is left to ANY_VALUE by the caller.
        def numeric(left, right, widest:)
          a = NUMERIC.index(left.kind)
          b = NUMERIC.index(right.kind)
          return ANY_VALUE unless a && b

          Descriptor.new(kind: NUMERIC[widest ? [ a, b ].max : [ a, b ].min], item: nil, of: nil, values: nil, pattern: nil, unique: nil)
        end

        # [element kind, definition] for the union of two lists or two maps; nil when nothing
        # precise can be said.
        def union_element(left, right)
          return [ left.item, left.of ] if left.item == right.item && left.of == right.of
          return nil unless left.of.nil? && right.of.nil?

          index = NUMERIC.index(left.item)
          other = NUMERIC.index(right.item)
          index && other ? [ NUMERIC[[ index, other ].max], nil ] : [ nil, nil ]
        end

        # The same for the intersection. A nil element kind means any JSON value.
        def common_element(left, right)
          return [ right.item, right.of ] if left.item.nil?
          return [ left.item, left.of ] if right.item.nil?
          return [ left.item, left.of ] if left.item == right.item && left.of == right.of
          return nil unless left.of.nil? && right.of.nil?

          index = NUMERIC.index(left.item)
          other = NUMERIC.index(right.item)
          index && other ? [ NUMERIC[[ index, other ].min], nil ] : nil
        end

        # Every literal either allows; nil when either leaves the choice open.
        def joined(left, right)
          left && right ? (left + right).uniq : nil
        end

        # Every literal both allow; nil when either leaves the choice open.
        def shared_values(left, right)
          left && right ? left & right : nil
        end

        # A pattern both state, or nil: two patterns joined cannot be written as one.
        def shared_pattern(left, right)
          left && right && left == right ? left : nil
        end

        def unique_or(left, right)
          left.nil? || right.nil? ? nil : left && right
        end

        def unique_and(left, right)
          return false if left == false || right == false
          return true if left == true || right == true

          nil
        end

        # --- what the two sources say about updating

        def read_flags
          FLAGS.each do |key, flag|
            Array(@schema[key]).each do |path|
              segments = segments_of(path)
              if segments.include?("*")
                cover_wildcard(segments, flag)
              else
                located = locate(segments)
                @flags[located] << flag if located
              end
            end
          end
        end

        # A wildcard flag path ("/properties/Parts/*/Role", or deeper:
        # "/properties/Rules/*/Outcomes/*/Arn") states the flag for a property of the
        # elements the wildcards stand in front of; the wildcard is the list index or map
        # key. AWS writes 183 such paths in us-east-1, with one to three stars, and every
        # one of them is of this middle shape. Resolved here, once, by walking the
        # descriptor tree: the literals up to each star locate a property, the star descends
        # into what that property holds, and the literals after the last star name the
        # flagged property.
        def cover_wildcard(segments, flag, container = ROOT)
          star = segments.index("*") or return finish_wildcard(segments, flag, container)
          located = locate(segments[0...star], container) or return
          nested = container_of(@descriptors.dig(located[0], located[1])) or return
          cover_wildcard(segments[(star + 1)..], flag, nested)
        end

        def finish_wildcard(rest, flag, container)
          located = locate(rest, container) if rest.any?
          @flags[located] << flag if located
        end

        def segments_of(path)
          path.is_a?(String) ? path.delete_prefix("/properties/").split("/") : []
        end

        # [definition name, property name] for a path under /properties, or nil when the
        # path does not lead to a property.
        def locate(segments, container = ROOT)
          return if segments.empty?

          found = @descriptors.dig(container, segments.first)
          return unless found
          return [ container, segments.first ] if segments.one?

          nested = container_of(found)
          locate(segments.drop(1), nested) if nested
        end

        # The definition describing what a property holds, when it holds objects.
        def container_of(descriptor)
          return nil unless descriptor.of && (descriptor.kind == :nested || descriptor.item == :nested)

          @descriptors.key?(descriptor.of) ? descriptor.of : nil
        end

        def read_specification
          resource = @specification.resource_type(@type_name) or return
          walk(ROOT, resource["Properties"], {})
          add_specification_only_properties(resource)
        end

        # The specification states an update type for every property, nested ones included,
        # under the names the provider schema uses. Both trees are walked together. At the
        # top level every property is recorded, the ones only the specification knows too,
        # so that create_only sees which of them it marks Immutable.
        def walk(container, properties, seen)
          return unless properties.is_a?(Hash)

          if container == ROOT
            properties.each do |property, specified|
              @specified[[ container, property ]] = said(specified) unless @descriptors.fetch(ROOT).key?(property)
            end
          end
          @descriptors.fetch(container).each do |property, descriptor|
            specified = properties[property] or next
            @specified[[ container, property ]] = said(specified)

            nested = container_of(descriptor) or next
            deeper = @specification.properties(@type_name, specified) or next
            next if seen[[ nested, deeper.object_id ]]

            seen[[ nested, deeper.object_id ]] = true
            walk(nested, deeper, seen)
          end
        end

        def said(specified)
          { "update" => UPDATES[specified["UpdateType"]], "duplicates" => specified["DuplicatesAllowed"] }
        end

        # A property only the specification knows is added after the provider's, as it describes it.
        def add_specification_only_properties(resource)
          unknown_to_provider = resource["Properties"].reject { |property,| @descriptors.fetch(ROOT).key?(property) }
          @extra = SpecificationType.new(@specification, @type_name).extra(unknown_to_provider)
          return if @extra.entries.empty?

          taken = @extra.definitions.keys & (@shapes.keys - [ ROOT ])
          raise RubyCdk::Error, "#{@type_name}: the provider schema and the specification both define #{taken.first.inspect}, and they may differ" if taken.any?
        end

        # --- the type

        def build
          type = {
            "source" => "provider",
            "documentation_url" => documentation_url,
            "required" => @shapes.fetch(ROOT).required.uniq.sort,
            "create_only" => create_only,
            "read_only" => read_only,
            "properties" => entries(ROOT),
            "definitions" => (@shapes.keys - [ ROOT ]).sort.to_h { |name| [ name, definition(name) ] }
          }
          type["additional_properties"] = true if additional_properties?
          if @extra && !@extra.entries.empty?
            type["properties"].concat(@extra.entries)
            type["definitions"].merge!(@extra.definitions)
          end
          type
        end

        # A type may take properties neither source lists when either says so. The provider
        # schema says `additionalProperties: false` of every type, which carries no
        # information; the one type the specification opens is AWS::CloudFormation::CustomResource.
        def additional_properties?
          return true if @schema["additionalProperties"] == true

          @specification.resource_type(@type_name)&.fetch("AdditionalProperties", nil) == true
        end

        def documentation_url
          url = @specification.resource_type(@type_name)&.fetch("Documentation", nil) || @schema["documentationUrl"]
          url&.sub(%r{\Ahttp://docs\.aws\.amazon\.com/}, "https://docs.aws.amazon.com/")
        end

        def create_only
          from_provider = Array(@schema["createOnlyProperties"]).map { |path| segments_of(path).join(".") }
          from_specification = @specified.filter_map { |(container, property), said| property if container == ROOT && said["update"] == "immutable" }
          (from_provider + from_specification).uniq.sort
        end

        def read_only
          attributes = @specification.resource_type(@type_name)&.fetch("Attributes", nil)
          from_specification = attributes.is_a?(Hash) ? attributes.keys : []
          (Array(@schema["readOnlyProperties"]).map { |path| segments_of(path).join(".") } + from_specification).uniq.sort
        end

        # [name, entry] pairs, in the provider schema's order.
        def entries(container)
          required = @shapes.fetch(container).required
          @descriptors.fetch(container).map { |property, descriptor| [ property, entry(container, property, descriptor, required.include?(property)) ] }
        end

        def definition(name)
          { "required" => @shapes.fetch(name).required.uniq.sort, "properties" => entries(name) }
        end

        def entry(container, property, descriptor, required)
          key = [ container, property ]
          entry = { "kind" => descriptor.kind.to_s }
          entry["item"] = descriptor.item.to_s if descriptor.item
          entry["of"] = descriptor.of if descriptor.of
          update = update_of(container, property, @specified[key])
          entry["update"] = update if update
          entry["values"] = descriptor.values unless descriptor.values.nil?
          entry["pattern"] = descriptor.pattern if descriptor.pattern
          unique = unique_items(descriptor, @specified[key])
          entry["unique"] = unique unless unique.nil?
          entry
        end

        # The provider schema's create-only list decides first: a create-only property is
        # immutable. Then comes the specification's UpdateType, which is where Mutable,
        # Immutable and Conditional come from. Only when the specification says nothing,
        # because it does not list the property or the type, does the provider schema's own
        # conditionalCreateOnlyProperties make it conditional; and a writable property
        # neither source mentions is mutable, since the provider schema passes it to the
        # update handler. A read-only property has no behaviour, since nothing updates it.
        #
        # The flags are the ones the provider schema states for the property's own path,
        # plus what wildcard flag paths cover it (see cover_wildcard): AWS::MSK::Replicator
        # writes its replication info as createOnlyProperties "/properties/ReplicationInfoList/*",
        # and 150 more properties travel only in such wildcard paths, all of which would
        # otherwise look writable to the diff.
        def update_of(container, property, said)
          flags = @flags[[ container, property ]]
          return "immutable" if flags.include?(:create_only)
          return nil if flags.include?(:read_only)
          return said["update"] if said && said["update"]
          return "conditional" if flags.include?(:conditional)

          "mutable"
        end

        # uniqueItems when the provider schema states it; otherwise what the specification's
        # DuplicatesAllowed says; otherwise nothing.
        def unique_items(descriptor, said)
          return descriptor.unique unless descriptor.unique.nil?
          return nil unless said && !said["duplicates"].nil?

          !said["duplicates"]
        end
      end
    end
  end
end
