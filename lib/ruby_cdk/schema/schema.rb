# frozen_string_literal: true

require "json"
require "zlib"
require_relative "../errors"
require_relative "type_schema"

module RubyCdk
  module Schema
    # The two files under data/spec, built by `rake spec:update` and never edited by hand.
    MODEL_FILE = "model.json.gz"
    META_FILE = "META.json"

    # The shape of the model. It changes only in a way an older loader cannot read.
    MODEL_FORMAT = 1

    # The kinds of a value, as the architecture lists them.
    KINDS = %i[string integer long double boolean timestamp json list map nested].freeze
    UPDATE_BEHAVIOURS = %i[mutable immutable conditional unknown].freeze

    KIND_NAMES = KINDS.to_h { |kind| [ kind.to_s, kind ] }.freeze
    UPDATE_NAMES = UPDATE_BEHAVIOURS.to_h { |behaviour| [ behaviour.to_s, behaviour ] }.freeze
    NOTHING = [].freeze

    # Where the gem keeps the model.
    DIR = File.expand_path("../../../data/spec", __dir__)

    class << self
      # The directory the model is read from: data/spec inside the gem.
      def dir
        DIR
      end

      # The TypeSchema of a resource type, or nil when no source describes it.
      def type(name)
        model.type(name)
      end

      def known_type?(name)
        model.known_type?(name)
      end

      # Every resource type the model knows, sorted.
      def types
        model.types
      end

      # The parsed META.json: the region, both sources, the counts and the model's SHA-256.
      def meta
        model.meta
      end

      # :mutable, :immutable, :conditional, or :unknown. See TypeSchema#update_behaviour.
      def update_type(type, path)
        model.update_type(type, path)
      end

      private

      # Parsed on the first lookup and kept.
      def model
        @model ||= Model.load(DIR)
      end
    end

    # The vendored model, parsed. Schema holds the one in the gem; a test can load
    # another directory.
    class Model
      attr_reader :dir, :region, :meta

      # Reads model.json.gz and META.json under dir.
      def self.load(dir)
        raw = read(File.join(dir, MODEL_FILE))
        format = raw.is_a?(Hash) ? raw["format"] : nil
        unless format == MODEL_FORMAT
          raise RubyCdk::Error, "the schema model in #{dir} has format #{format.inspect} and this version of ruby-cdk reads " \
                                "format #{MODEL_FORMAT}: rebuild it with `rake spec:update`, or update the gem"
        end

        new(dir:, raw:, meta: read_meta(File.join(dir, META_FILE)))
      end

      def self.read(path)
        raise RubyCdk::Error, "the schema model is missing at #{path}: the gem is not installed completely" unless File.file?(path)

        JSON.parse(Zlib.gunzip(File.binread(path)))
      rescue Zlib::GzipFile::Error, JSON::ParserError
        raise RubyCdk::Error, "the schema model at #{path} is not a gzip of one JSON object: rebuild it with `rake spec:update`"
      end

      def self.read_meta(path)
        raise RubyCdk::Error, "#{path} is missing: the gem is not installed completely" unless File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        raise RubyCdk::Error, "#{path} is not JSON: rebuild it with `rake spec:update`"
      end

      def initialize(dir:, raw:, meta:)
        @dir = dir
        @region = raw["region"]
        @raw_types = raw.fetch("types")
        @meta = meta
        @types = {}
        @names = nil
      end

      # The TypeSchema of a resource type, or nil. Built on first use and kept.
      def type(name)
        raw = @raw_types[name]
        return nil unless raw

        @types[name] ||= build(name, raw)
      end

      def known_type?(name)
        @raw_types.key?(name)
      end

      # Every resource type, sorted.
      def types
        @names ||= @raw_types.keys.sort.freeze
      end

      # See TypeSchema#update_behaviour.
      def update_type(type, path)
        schema = type(type)
        schema ? schema.update_behaviour(path) : :unknown
      end

      private

      def build(name, raw)
        TypeSchema.new(
          name:,
          properties: properties_of(raw["properties"], raw["required"]),
          definitions: raw.fetch("definitions", {}).to_h do |definition, body|
            [ definition, Definition.new(name: definition, properties: properties_of(body["properties"], body["required"]), required: list(body["required"])) ]
          end.freeze,
          required: list(raw["required"]),
          create_only: list(raw["create_only"]),
          read_only: list(raw["read_only"]),
          documentation_url: raw["documentation_url"],
          source: raw.fetch("source").to_sym,
          additional_properties: raw["additional_properties"] == true
        )
      end

      # A Hash of name to PropertySchema, in the model's order, which is the source's.
      def properties_of(entries, required)
        required = Array(required)
        entries.to_h do |name, entry|
          [ name, PropertySchema.new(
            name:,
            kind: KIND_NAMES.fetch(entry["kind"]) { unknown("kind", entry["kind"]) },
            item_kind: entry["item"] && KIND_NAMES.fetch(entry["item"]) { unknown("item kind", entry["item"]) },
            definition: entry["of"],
            required: required.include?(name),
            update_behaviour: entry["update"] ? UPDATE_NAMES.fetch(entry["update"]) { unknown("update behaviour", entry["update"]) } : :unknown,
            allowed_values: entry["values"]&.dup&.freeze,
            pattern: entry["pattern"],
            unique_items: entry["unique"]
          ) ]
        end.freeze
      end

      def unknown(what, value)
        raise RubyCdk::Error, "the schema model names an unknown #{what}, #{value.inspect}: rebuild it with `rake spec:update`"
      end

      def list(value)
        value.nil? || value.empty? ? NOTHING : value.dup.freeze
      end
    end
  end
end
