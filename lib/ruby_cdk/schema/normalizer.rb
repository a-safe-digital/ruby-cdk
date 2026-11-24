# frozen_string_literal: true

require_relative "../schema"
require_relative "validator/template"

module RubyCdk
  module Validation
    # The normalizer of architecture §6: the template with every key CloudFormation
    # knows written under the name CloudFormation knows it by, and every other key exactly
    # as it was written. It answers a new Hash and changes nothing it was given.
    #
    # What the CDK does was read first, at commit 68b2516c09791d78b199f30e455e4670dc9cde6.
    # It resolves no key: the fromCloudFormation of its generated classes match a
    # CloudFormation name exactly, and a property they do not know is kept as written
    # (packages/aws-cdk-lib/core/lib/helpers-internal/cfn-parse.ts,
    # FromCloudFormationPropertyObject.addUnrecognizedPropertiesAsExtra), which is why
    # its own test accepts properties that are not in the specification
    # (cloudformation-include/test/test-templates/properties-not-in-cfn-spec.json). The
    # resolution of snake_case is this tool's own, and architecture §6 is its rule:
    #
    # 1. An exact match with a property name is used as is.
    # 2. Otherwise the key is matched without regard to case and to underscores. Exactly
    #    one match: that property's name is written.
    # 3. No match, or several: the key is left as written, for rule V3 or V4 to report.
    #
    # Verbatim zones, where nothing is resolved and a symbol becomes a string: a property of
    # kind :json (the policy documents), the Metadata of a resource, and everything under
    # a type the model does not know (rule V1), since nothing can say what its keys mean.
    module Normalizer
      # The outcomes of key resolution, as resolve answers them.
      OUTCOMES = %i[exact unique none ambiguous].freeze

      # How a node's property names fold, kept per node. The nodes are the model's own
      # frozen objects, which live as long as the model does.
      FOLDED = {}.compare_by_identity

      module_function

      # What the pipeline calls: the normalized template of the context.
      def call(context)
        normalize(context.template)
      end

      # The template with the Properties of every resource normalized.
      def normalize(template)
        return template unless template.is_a?(Hash)

        template.to_h do |section, value|
          [ section, section == "Resources" ? resources(value) : value ]
        end
      end

      # How a key names a property of a node: the outcome (one of OUTCOMES) and the
      # property it names, or nil when it names none or cannot be told from another.
      def resolve(key, node)
        property = node.properties[key]
        return [ :exact, property ] if property

        matches = folded(node)[Template.fold(key)]
        case matches&.size
        when 1 then [ :unique, node.properties[matches.first] ]
        when nil, 0 then [ :none, nil ]
        else [ :ambiguous, nil ]
        end
      end

      # The property a key names, written exactly or in snake_case, or nil.
      def lookup(node, key)
        node.properties[key] || resolve(key, node)[1]
      end

      def folded(node)
        FOLDED[node] ||= node.properties.keys.group_by { |name| Template.fold(name) }
      end

      def resources(section)
        return section unless section.is_a?(Hash)

        section.to_h do |name, body|
          [ name, body.is_a?(Hash) ? resource(body) : body ]
        end
      end

      def resource(body)
        body.to_h do |attribute, value|
          case attribute
          when "Properties" then [ attribute, properties(value, Template.resource_type(body)) ]
          when "Metadata" then [ attribute, verbatim(value) ]
          else [ attribute, value ]
          end
        end
      end

      # A type the model does not know, or knows no property of, is written verbatim.
      def properties(value, type)
        schema = type && Schema.type(type)
        schema && !schema.properties.empty? ? node(schema, schema, value) : verbatim(value)
      end

      # The keys of an object under a node the model describes.
      def node(type, current, value)
        return verbatim(value) unless value.is_a?(Hash) && !Template.intrinsic?(value)

        value.to_h do |key, item|
          outcome, property = resolve(key.to_s, current)
          named = outcome == :exact || outcome == :unique ? property.name : key.to_s
          [ named, property ? descend(type, property, item) : verbatim(item) ]
        end
      end

      # A property's value: verbatim under :json, normalized under :nested, a list or a map
      # of objects, and as it is everywhere else.
      def descend(type, property, value)
        return verbatim(value) if property.kind == :json

        in_branches(value) do |item|
          next item if Template.intrinsic?(item)
          next item unless item.is_a?(Hash) || item.is_a?(Array)

          definition = type.definitions[property.definition]
          next item unless definition

          case [ property.kind, property.item_kind ]
          when [ :nested, nil ]
            item.is_a?(Hash) ? node(type, definition, item) : item
          when [ :list, :nested ]
            item.is_a?(Array) ? item.map { |element| object(type, definition, element) } : item
          when [ :map, :nested ]
            item.is_a?(Hash) ? item.to_h { |key, element| [ key.to_s, object(type, definition, element) ] } : item
          else item
          end
        end
      end

      def object(type, definition, value)
        in_branches(value) { |item| item.is_a?(Hash) && !Template.intrinsic?(item) ? node(type, definition, item) : item }
      end

      # The value with each branch of its Fn::If replaced by what the block makes of it,
      # branches of branches included. The value itself, block untouched, when it is no Fn::If
      # of three parts.
      def in_branches(value)
        return yield(value) unless Template.function?(value, "Fn::If")

        list = value["Fn::If"]
        return value unless list.is_a?(Array) && list.size == 3

        branches = list[1, 2]
        return value unless branches.is_a?(Array)

        value.merge("Fn::If" => [ list[0], *branches.map { |branch| in_branches(branch) { |inner| yield inner } } ])
      end

      # Keys exactly as written, symbols as strings, all the way down.
      def verbatim(value)
        case value
        when Hash then value.to_h { |key, item| [ key.to_s, verbatim(item) ] }
        when Array then value.map { |item| verbatim(item) }
        else value
        end
      end
    end
  end
end
