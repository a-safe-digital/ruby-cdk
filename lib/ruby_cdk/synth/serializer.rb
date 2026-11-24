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
      SECTION_ORDER = %w[AWSTemplateFormatVersion Transform Description Parameters Mappings Conditions Resources Outputs Metadata].freeze

      # The attributes of a resource, in this order.
      RESOURCE_ATTRIBUTE_ORDER = %w[Type DependsOn Condition Metadata DeletionPolicy UpdateReplacePolicy Properties].freeze

      # JSON.generate with these options writes two-space indentation, one space
      # after each colon and one value per line.
      OPTIONS = { indent: "  ", space: " ", object_nl: "\n", array_nl: "\n" }.freeze

      module_function

      # The bytes of a template: UTF-8 JSON with LF line endings and one trailing newline.
      def call(template)
        render(ordered(template))
      end

      # The same bytes for any plain Hash: the manifest uses them too.
      #
      # JSON.generate would write anything else through its to_s, so the Hash is
      # checked first: it holds strings, numbers, booleans and nil, in arrays and
      # in hashes whose keys are strings, and nothing else.
      def render(hash)
        check(hash, [])
        JSON.generate(hash, **OPTIONS) + "\n"
      rescue JSON::JSONError => e
        Kernel.raise SerializationError, "a template holds only strings, numbers, booleans, arrays and hashes: #{e.message}"
      end

      # Where a stack's template is written.
      def path(out_dir, stack_name)
        File.join(out_dir, "#{stack_name}#{FILE_SUFFIX}")
      end

      # The template as it is written: top-level sections in SECTION_ORDER,
      # every resource with its attributes in RESOURCE_ATTRIBUTE_ORDER, and
      # anything else in the order it was given. A section or an attribute with
      # nothing in it is left out.
      def ordered(template)
        (SECTION_ORDER | template.keys).each_with_object({}) do |name, done|
          section = template[name]
          next if empty?(section)

          done[name] = name == "Resources" && section.is_a?(Hash) ? order_resources(section) : section
        end
      end

      def order_resources(resources)
        resources.to_h { |name, body| [ name, body.is_a?(Hash) ? order_resource(body) : body ] }
      end

      def order_resource(body)
        (RESOURCE_ATTRIBUTE_ORDER | body.keys).each_with_object({}) do |name, ordered|
          ordered[name] = body[name] unless empty?(body[name])
        end
      end

      def empty?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end

      # Raises SerializationError naming the place of the first value that is not plain data.
      def check(value, place)
        case value
        when String, Integer, true, false, nil
          nil
        when Float
          not_plain(value, place) unless value.finite?
        when Array
          value.each_with_index { |item, index| check(item, place + [ "[#{index}]" ]) }
        when Hash
          value.each do |key, item|
            not_plain(key, place, "a key") unless key.is_a?(String)
            check(item, place + [ key ])
          end
        else
          not_plain(value, place)
        end
      end

      def not_plain(value, place, what = nil)
        kind = what || "a #{value.class}"
        Kernel.raise SerializationError, "#{where(place)}: #{kind} is not plain data: #{short(value)} cannot be written"
      end

      # A place in the template, as "Resources.A.Properties.Tags[0]".
      def where(place)
        return "the template" if place.empty?

        place.each_with_object(+"") do |segment, text|
          next text << segment if segment.start_with?("[")

          text << "." unless text.empty?
          text << segment
        end
      end

      def short(value)
        value.to_s.size > 60 ? "#{value.to_s[0, 60]}..." : value.to_s
      end
      private_class_method :order_resources, :order_resource, :empty?, :check, :not_plain, :where, :short
    end
  end
end
