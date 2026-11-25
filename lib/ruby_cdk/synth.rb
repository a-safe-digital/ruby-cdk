# frozen_string_literal: true

require_relative "core"
require_relative "synth/resolver"
require_relative "synth/rules"
require_relative "synth/serializer"
require_relative "synth/manifest"
require_relative "synth/writer"

module RubyCdk
  # Synthesis (architecture §5): prepare, resolve, normalize, validate,
  # serialize, write.
  #
  # The pipeline knows the normalizers, the validators and what the manifest
  # says about other components only through what is registered here. A later
  # component adds a normalizer or validators with register_normalizer and
  # register_validator, and the pipeline does not change. The two validators of
  # this component are registered the same way, at the end of this file.
  #
  #   Resolver     the resolve phase
  #   Rules        V2 on logical IDs and V13 on the stack name
  #   Serializer   the bytes, and the serialization contract
  #   Manifest     what was written, as manifest.json says it
  #   Writer       a file is written only when its bytes changed
  module Synth
    # What a normalizer and a validator receive.
    #
    #   stack     the RubyCdk::Stack, live
    #   template  the template as it stands: a plain Hash with String keys
    #   issues    what the phases before found
    Context = Data.define(:stack, :template, :issues)

    # What one stack's synthesis produced. issues is empty unless something is
    # wrong; warnings is what a validator answered as a warning: reported on
    # the result, but it neither fails the synthesis nor stops the write. The
    # manifest ignores warnings; a command reads them off the result.
    Result = Data.define(:stack, :template, :bytes, :issues, :warnings)

    class << self
      # --- what other components register

      # normalizer answers call(context) with the normalized template, a new
      # Hash: the one it was given is not changed. Normalizers run in the
      # order they were registered, after resolve and before the validators.
      def register_normalizer(normalizer)
        check_callable(normalizer, "A normalizer")
        normalizers_registry << normalizer
        nil
      end

      def unregister_normalizer(normalizer)
        normalizers_registry.delete(normalizer)
        nil
      end

      def normalizers
        normalizers_registry.dup.freeze
      end

      # validator answers call(context) with an Array of RubyCdk::Issue. The
      # template it sees is exactly what would be written. Validators run in
      # the order they were registered, and every issue of every validator of
      # every stack is reported in one ValidationError.
      def register_validator(validator)
        check_callable(validator, "A validator")
        validators_registry << validator
        nil
      end

      def unregister_validator(validator)
        validators_registry.delete(validator)
        nil
      end

      def validators
        validators_registry.dup.freeze
      end

      # provider answers call with what manifest.json writes under key at the
      # top level: "schema_version". A key nobody registered is written as null.
      def register_manifest_fact(key, &provider)
        check_fact(key, provider, "A manifest fact")
        manifest_facts[key] = provider
        nil
      end

      def manifest_fact(key)
        manifest_facts[key]&.call
      end

      def manifest_fact_keys
        manifest_facts.keys.freeze
      end

      def unregister_manifest_fact(key)
        manifest_facts.delete(key)
        nil
      end

      # provider answers call(stack, template) with what every stack's entry
      # writes under key: the hashes of its assets.
      def register_entry_fact(key, &provider)
        check_fact(key, provider, "An entry fact")
        entry_facts[key] = provider
        nil
      end

      def entry_fact(key, stack, template)
        entry_facts[key]&.call(stack, template)
      end

      def unregister_entry_fact(key)
        entry_facts.delete(key)
        nil
      end

      # --- the phases

      # Every phase except write, for one stack. Never raises ValidationError:
      # result.issues says what is wrong, and result.warnings what a validator
      # meant as a warning.
      #
      #   prepare   the prepare hooks, children first, once per node
      #   resolve   the live tree becomes a plain template; Lazy values run here
      #   normalize the registered normalizers, in order
      #   serialize the template is put in the order it is written in
      #   validate  the registered validators, on exactly that template
      def run(stack)
        issues = []
        warnings = []
        stack.prepare_tree                                        # prepare
        template = Resolver.new(stack, issues:).call              # resolve
        normalizers.each do |normalizer|                          # normalize
          template = normalizer.call(context(stack, template, issues))
          unless template.is_a?(Hash)
            raise Error, "#{normalizer} returned a #{template.class}, and a normalizer returns the template as a Hash"
          end
        end
        template = Serializer.ordered(template)                   # serialize, the template as it is written
        validators.each do |validator|                            # validate
          Array(validator.call(context(stack, template, issues))).each do |issue|
            # A warning is an issue that answers warning? with true; this tool
            # does not name the class, the answer is the contract.
            if issue.respond_to?(:warning?) && issue.warning?
              warnings << issue
            else
              issues << issue
            end
          end
        end
        Result.new(stack:, template:, bytes: Serializer.render(template), issues: issues.freeze,
          warnings: warnings.freeze)  # serialize, the bytes
      end

      # Every phase except write, for one stack. Raises one ValidationError
      # holding every issue when anything is wrong; a warning never raises.
      def synthesize(stack)
        result = run(stack)
        raise ValidationError.new(result.issues) unless result.issues.empty?

        result
      end

      # Every phase on every stack of the app, in the order the stacks were
      # created. One ValidationError holds every issue of every stack, and
      # nothing is written when there is one. A warning rides along on its
      # result, which the manifest takes and ignores.
      def synthesize_app(app)
        results = app.stacks.map { |stack| run(stack) }
        failing = results.select { |result| result.issues.any? }
        if failing.any?
          raise ValidationError.new(failing.flat_map { |result| qualify(result, results.length > 1) })
        end

        Manifest.write(app, results)
      end

      private

      def normalizers_registry
        @normalizers_registry ||= []
      end

      def validators_registry
        @validators_registry ||= []
      end

      def manifest_facts
        @manifest_facts ||= {}
      end

      def entry_facts
        @entry_facts ||= {}
      end

      def check_callable(object, what)
        raise ArgumentError, "#{what} must answer call, got #{object.inspect}" unless object.respond_to?(:call)
      end

      def check_fact(key, provider, what)
        unless key.is_a?(String) && !key.empty? && provider
          raise ArgumentError, "#{what} needs a name and a block that answers its value"
        end
      end

      def context(stack, template, issues)
        Context.new(stack:, template:, issues: issues.dup.freeze)
      end

      # With several stacks an issue says which one it is about: "blog:Resources.Table".
      def qualify(result, name_the_stack)
        return result.issues unless name_the_stack

        result.issues.map do |issue|
          Issue.new(rule: issue.rule, path: "#{result.stack.stack_name}:#{issue.path}", message: issue.message, hint: issue.hint)
        end
      end
    end
  end

  # The tree's contract declares these; here are their implementations, in the
  # component that knows the pipeline.
  class Stack
    # Every phase of architecture §5 except write, as the template the stack would write.
    def to_template
      Synth.synthesize(self).template
    end

    # One value the way the template holds it: Lazy values resolved, symbols
    # as strings, an Fn::Join at its shortest. Raises ValidationError when the
    # value cannot be written.
    def resolve(value)
      Synth::Resolver.new(self).resolve(value)
    end
  end

  class App
    def synth
      Synth.synthesize_app(self)
    end
  end
end

RubyCdk::Synth.register_validator(RubyCdk::Synth::Rules::LogicalIds.new)
RubyCdk::Synth.register_validator(RubyCdk::Synth::Rules::StackName.new)
