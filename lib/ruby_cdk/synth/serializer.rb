# frozen_string_literal: true

require "json"
require_relative "../errors"

module RubyCdk
  module Synth
    # Raised when the template is not plain JSON data by the time it is serialized.
    class SerializationError < RubyCdk::Error; end

    # The serialization contract (architecture §5, D-028). Every byte of a
    # template comes from here.
    module Serializer
      FORMAT_VERSION = "2010-09-09"
      FILE_SUFFIX = ".template.json"

      # Top-level sections, in this order, each present only when it has something in it.
      SECTION_ORDER = %w[AWSTemplateFormatVersion Description Parameters Mappings Conditions Resources Outputs Metadata].freeze

      # The attributes of a resource, in this order.
      RESOURCE_ATTRIBUTE_ORDER = %w[Type DependsOn Condition Metadata DeletionPolicy UpdateReplacePolicy Properties].freeze

      # JSON.generate with these options writes two-space indentation, one space
      # after each colon and one value per line.
      OPTIONS = { indent: "  ", space: " ", object_nl: "\n", array_nl: "\n" }.freeze

      module_function

      # The bytes of a template: UTF-8 JSON with LF line endings and one trailing newline.
      def call(template)
        render(order(template))
      end

      # The same bytes for any plain Hash: the manifest uses them too.
      def render(hash)
        JSON.generate(hash, **OPTIONS) + "\n"
      rescue JSON::JSONError => e
        raise SerializationError, "a template holds only strings, numbers, booleans, arrays and hashes: #{e.message}"
      end

      # Where a stack's template is written.
      def path(out_dir, stack_name)
        File.join(out_dir, "#{stack_name}#{FILE_SUFFIX}")
      end

      # The template with its top-level sections in SECTION_ORDER, and every
      # resource with its attributes in RESOURCE_ATTRIBUTE_ORDER. Anything else
      # keeps the order it was given. A section with nothing in it is left out.
      def order(template)
        (SECTION_ORDER | template.keys).each_with_object({}) do |name, ordered|
          section = template[name]
          next if section.nil? || (section.respond_to?(:empty?) && section.empty?)

          ordered[name] = name == "Resources" && section.is_a?(Hash) ? order_resources(section) : section
        end
      end

      def order_resources(resources)
        resources.to_h { |name, body| [ name, body.is_a?(Hash) ? order_resource(body) : body ] }
      end

      # The attributes in RESOURCE_ATTRIBUTE_ORDER and then any other, in the
      # order they were given. An attribute that is nil or empty is left out.
      def order_resource(body)
        (RESOURCE_ATTRIBUTE_ORDER | body.keys).each_with_object({}) do |name, ordered|
          attribute = body[name]
          next if attribute.nil? || (attribute.respond_to?(:empty?) && attribute.empty?)

          ordered[name] = attribute
        end
      end
      private_class_method :order, :order_resources, :order_resource
    end
  end
end
