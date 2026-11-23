# frozen_string_literal: true

require "digest"
require_relative "../errors"
require_relative "../version"
require_relative "serializer"
require_relative "writer"

module RubyCdk
  module Synth
    # What synthesis wrote (architecture §12): manifest.json and, in it, one
    # entry per stack. A template carries nothing that varies from one machine
    # to another; the manifest does.
    class Manifest
      FILE_NAME = "manifest.json"

      # The key that says which model was consulted. The component that owns
      # the model registers it with Synth.register_manifest_fact; until one
      # does it is written as null.
      SCHEMA_VERSION_KEY = "schema_version"

      # The key of every stack's entry that lists the hashes of its assets.
      # The component that owns assets registers it with Synth.register_entry_fact.
      ASSETS_KEY = "assets"

      # One stack. env is nil for a stack that goes wherever the credentials point.
      Entry = Data.define(:name, :template, :template_hash, :env, :dependencies, :assets) do
        def to_h
          {
            "name" => name, "template" => template, "template_hash" => template_hash,
            "env" => env, "dependencies" => dependencies, "assets" => assets
          }
        end
      end

      include Enumerable

      attr_reader :out_dir, :path, :entries

      def initialize(out_dir:, entries:)
        @out_dir = out_dir
        @path = File.join(out_dir, FILE_NAME)
        @entries = entries.freeze
      end

      alias_method :stacks, :entries

      def each(&block)
        entries.each(&block)
      end

      # The manifest as the file holds it.
      def to_h
        manifest = { "ruby_cdk_version" => RubyCdk::VERSION }
        ([ SCHEMA_VERSION_KEY ] | Synth.manifest_fact_keys).each { |key| manifest[key] = Synth.manifest_fact(key) }
        manifest["stacks"] = entries.map(&:to_h)
        manifest
      end

      # The bytes of manifest.json.
      def bytes
        Serializer.render(to_h)
      end

      class << self
        # The write phase: every template whose bytes changed, then the
        # manifest. Returns what was written.
        def write(app, results)
          manifest = build(app, results)
          Writer.mkdir(app.out_dir)
          results.each do |result|
            Writer.write_if_changed(Serializer.path(app.out_dir, result.stack.stack_name), result.bytes)
          end
          Writer.write_if_changed(manifest.path, manifest.bytes)
          manifest
        end

        # The manifest of results, each a Result of Synth.run, without writing anything.
        def build(app, results)
          new(out_dir: app.out_dir, entries: results.map { |result| entry_of(result, app) })
        end

        private

        def entry_of(result, app)
          stack = result.stack
          Entry.new(
            name: stack.stack_name,
            template: File.basename(Serializer.path(app.out_dir, stack.stack_name)),
            template_hash: "sha256:#{Digest::SHA256.hexdigest(result.bytes)}",
            env: stack.env && { "account" => stack.env.account, "region" => stack.env.region },
            dependencies: dependencies_of(stack, app, result.template),
            assets: Synth.entry_fact(ASSETS_KEY, stack, result.template) || []
          )
        end

        # The stacks this one is deployed after: those it was made to depend
        # on, then those whose export it imports by name.
        def dependencies_of(stack, app, template)
          names = stack.dependencies.map(&:stack_name)
          imported = imported_names(template)
          app.stacks.each do |other|
            next if other.equal?(stack) || names.include?(other.stack_name)

            exports = other.outputs.any? do |_, output|
              output.export && imported.include?(other.export_name(output.id))
            end
            names << other.stack_name if exports
          end
          names
        end

        # Every name written as {"Fn::ImportValue" => name} in the template.
        def imported_names(value, found = [])
          case value
          when Hash
            value.each do |key, item|
              key == "Fn::ImportValue" && item.is_a?(String) ? found << item : imported_names(item, found)
            end
          when Array
            value.each { |item| imported_names(item, found) }
          end
          found
        end
      end
    end
  end
end
