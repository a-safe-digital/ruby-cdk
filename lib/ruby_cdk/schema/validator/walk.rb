# frozen_string_literal: true

require_relative "../normalizer"
require_relative "template"

module RubyCdk
  module Validation
    # Walks a resource's properties the way the schema model describes them. Nothing here
    # knows a rule: it is how the rules reach every node and every value the model names.
    #
    # A node is a TypeSchema or one of its Definitions: both answer properties and required.
    # A key is read as the normalizer reads it (Normalizer.lookup), so the walk reaches the
    # same values whether or not the template was normalized.
    #
    # The walk stops where the model stops: at a value of kind :json, past a scalar, and at
    # every intrinsic, which stands for a value only CloudFormation will know. An Fn::If is
    # the exception: each of its branches stands for the property's value, so each is
    # walked as that value would have been (the CDK leaves an intrinsic alone,
    # packages/aws-cdk-lib/core/lib/runtime.ts, canInspect, and keeps both branches of an
    # Fn::If in helpers-internal/cfn-parse.ts).
    module SchemaWalk
      module_function

      # Yields [ type, node, hash, segments ] for the resource's properties (node is then
      # the type itself) and for every object below them that the model describes.
      def each_node(type, properties, segments = [], &block)
        visit_node(type, type, properties, segments, block)
      end

      # Yields [ type, node, property, value, segments ] for every value the model gives a
      # kind, under the resource's properties: a list as the list, each of its elements,
      # and so on. node is the type or the definition the property belongs to.
      def each_value(type, properties, segments = [], &block)
        visit_values(type, type, properties, segments, block)
      end

      def visit_node(type, node, value, segments, block)
        return unless value.is_a?(Hash) && !Template.intrinsic?(value)

        block.call(type, node, value, segments)
        value.each do |key, item|
          property = Normalizer.lookup(node, key.to_s)
          visit_node_property(type, property, item, segments + [ key.to_s ], block) if property
        end
      end

      def visit_values(type, node, hash, segments, block)
        return unless hash.is_a?(Hash) && !Template.intrinsic?(hash)

        hash.each do |key, item|
          property = Normalizer.lookup(node, key.to_s)
          visit_value(type, node, property, item, segments + [ key.to_s ], block) if property
        end
      end

      def visit_node_property(type, property, value, segments, block)
        definition = type.definitions[property.definition]
        return unless definition

        branches(value, segments) do |inner, path|
          objects(property, inner, path) { |object, at| visit_node(type, definition, object, at, block) }
        end
      end

      def visit_value(type, node, property, value, segments, block)
        branches(value, segments) do |inner, path|
          block.call(type, node, property, inner, path)
          definition = type.definitions[property.definition]
          objects(property, inner, path) { |object, at| visit_values(type, definition, object, at, block) } if definition
        end
      end

      # Yields the value where a property has one, or each branch of an Fn::If in its place
      # (and a branch of a branch, and so on). Never a nil, never another intrinsic: those
      # stand for nothing a rule can look at.
      def branches(value, segments)
        if Template.function?(value, "Fn::If")
          list = value["Fn::If"]
          return unless list.is_a?(Array) && list.size == 3

          branches = list[1, 2]
          return unless branches.is_a?(Array)

          branches.each_with_index do |branch, index|
            path = segments + [ "Fn::If", "[#{index + 1}]" ]
            next if branch.nil? || (Template.intrinsic?(branch) && !Template.function?(branch, "Fn::If"))

            branches(branch, path) { |inner, at| yield inner, at }
          end
        elsif !value.nil? && !Template.intrinsic?(value)
          yield value, segments
        end
      end

      # Yields each object a property holds a definition for: the value of a :nested
      # property, each object of a list or a map of them. Nothing when the model stops here.
      def objects(property, value, segments)
        case [ property.kind, property.item_kind ]
        when [ :nested, nil ]
          yield value, segments if value.is_a?(Hash)
        when [ :list, :nested ]
          value.each_with_index { |item, index| yield item, segments + [ "[#{index}]" ] } if value.is_a?(Array)
        when [ :map, :nested ]
          value.each { |key, item| yield item, segments + [ key.to_s ] } if value.is_a?(Hash)
        end
      end

      # Yields [ definition, segments ] for each nil element of a list of objects with
      # required properties. A nil where such an object belongs is how a template says
      # "nothing here", and its required properties are missing, as the CDK's list
      # validators report (core/lib/runtime.ts: "allowedMethods: required but missing").
      def each_nil_element(type, property, value, segments)
        return unless property.kind == :list && property.item_kind == :nested && value.is_a?(Array)

        definition = type.definitions[property.definition]
        return unless definition

        value.each_with_index { |item, index| yield definition, segments + [ "[#{index}]" ] if item.nil? }
      end
    end
  end
end
