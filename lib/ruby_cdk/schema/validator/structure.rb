# frozen_string_literal: true

require_relative "rule"
require_relative "scans"
require_relative "template"

module RubyCdk
  module Validation
    # The rules over what a template says about its resources and its sections: their
    # types, their properties and their values (architecture §6: V1 to V7, V12, V13 and
    # V16 to V19). Each is a class, with its id, that answers the issues it finds.
    module Rules
      # V1: a resource type the model knows. One it does not know is a warning: its keys
      # are written as given (the normalizer) and nothing else is checked of it. That is
      # what lets a Custom::* resource, or one of a private registry, through; with
      # strict_types it is an error. A resource with no type at all is always an error.
      #
      # The engine behind the CDK's own validation reports a type it does not know as
      # F3006, and the CDK downgrades it to a warning unless asked to be strict
      # (aws-cloudformation/cloudformation-validate@55ff54b6, src/rules/src/registry.rs;
      # aws/aws-cdk@68b2516c, core/lib/private/synthesis-validation.ts,
      # downgradeCfnValidateErrorsToWarnings).
      class KnownTypes < Rule
        rule "V1"

        def initialize(strict_types: false)
          @strict_types = strict_types
        end

        def call(context)
          issues = []
          Scans::Resources.each(context) do |name, body, path|
            type = Template.resource_type(body)
            if type.nil?
              issues << error(path + [ "Type" ], "the resource #{name} has no Type",
                hint: "every resource names its type, as \"AWS::S3::Bucket\"")
            elsif !Schema.known_type?(type)
              issues << unknown(path + [ "Type" ], type)
            end
          end
          issues
        end

        private

        def unknown(path, type)
          message = "#{type.inspect} is not a resource type the schema model knows: its properties are written as you give them, " \
                    "and nothing else is checked of this resource"
          near = Text.closest(type, Schema.types)
          hint = +"check the spelling"
          hint << "; did you mean #{Text.list(near)}?" unless near.empty?
          hint << ". With --strict-types this is an error"
          @strict_types ? error(path, message, hint:) : warning(path, message, hint:)
        end
      end

      # V2: a logical ID holds letters and digits only, and a parameter and a resource
      # never share one.
      #
      # The pipeline runs a V2 of its own from the tree (synth/rules.rb); this one is for a
      # template with no tree behind it. It checks what the CDK's engine checks
      # (aws-cloudformation/cloudformation-validate@55ff54b6, src/rules/src/registry.rs
      # and src/cel-engine/src/rules/structure.rs): the characters, under F0006, F2003,
      # F6004 and E7001, and the one clash CloudFormation refuses, a parameter and a
      # resource of one name, under F3007. A condition and a resource may share a name,
      # and so may an output and a resource: the CDK's own include tests synthesize both
      # (aws/aws-cdk@68b2516c, cloudformation-include/test/test-templates/
      # condition-same-name-as-resource.json and outputs-with-references.json).
      class LogicalIds < Rule
        rule "V2"

        PATTERN = /\A[A-Za-z0-9]+\z/
        SECTIONS = %w[Parameters Mappings Conditions Resources Outputs].freeze

        def call(context)
          template = context.template
          return [] unless template.is_a?(Hash)

          issues = SECTIONS.flat_map do |section|
            Template.section(template, section).keys.filter_map do |name|
              next if name.to_s.match?(PATTERN)

              error([ section, name.to_s ], "the logical ID #{name.inspect} must hold letters and digits only",
                hint: "CloudFormation takes no \"_\", \"-\" or \".\" in a logical ID: write #{suggestion(name)}")
            end
          end
          issues.concat(clashes(template))
        end

        private

        # "my_table" as "MyTable", as the pipeline's V2 says it.
        def suggestion(name)
          name.to_s.split(/[^A-Za-z0-9]+/).map(&:capitalize).join
        end

        def clashes(template)
          parameters = Template.section(template, "Parameters").keys.map(&:to_s)
          Template.section(template, "Resources").keys.map(&:to_s).select { |name| parameters.include?(name) }.map do |name|
            error([ "Resources", name ], "the logical ID #{name.inspect} is declared more than once in the stack: in Parameters.#{name} and here",
              hint: "a logical ID names one thing in the whole stack")
          end
        end
      end

      # V3: a property exists on the type. What the normalizer could not resolve is still
      # written as it was; this is the one place that says so, with the closest names. A
      # type that takes properties it does not list (AWS::CloudFormation::CustomResource)
      # and a value the model stops at (a policy document) are not checked.
      #
      # F3002 of the CDK's engine: additional properties are not allowed.
      class Properties < Rule
        rule "V3"

        def call(context)
          issues = []
          Scans::Keys.unresolved(context) do |key, outcome, names, at, owner|
            next unless outcome == :none

            near = Text.closest(key, names)
            message = "#{key.inspect} is not a property of #{owner}"
            message << "; did you mean #{Text.list(near)}?" unless near.empty?
            hint = if near.empty? && names.size <= 12
              "its properties are #{Text.list(names)}"
            else
              "write the CloudFormation name, or in snake_case: #{Text.list(near.map { |name| Template.snake(name) })}"
            end
            issues << error(at, message, hint:)
          end
          issues
        end
      end

      # V4: a key names one property. It is written as it was when, read without regard to
      # case and underscores, it could be more than one of them.
      class AmbiguousProperties < Rule
        rule "V4"

        def call(context)
          issues = []
          Scans::Keys.unresolved(context) do |key, outcome, names, at, owner|
            next unless outcome == :ambiguous

            matches = names.select { |name| Template.fold(name) == Template.fold(key) }
            issues << error(at, "#{key.inspect} could name #{Text.list(matches)} of #{owner}",
              hint: "write the CloudFormation name of the one you mean")
          end
          issues
        end
      end

      # V5: the properties a type lists as required are there, at every level the model
      # describes. A nil is absent, an Fn::If is present, and so is a property the
      # template sets even where the model says nothing may be read from it.
      #
      # The messages follow the CDK's own validators: a missing property at the top is
      # "is missing required property: name", one inside a list is "name: required but
      # missing" (packages/aws-cdk-lib/core/lib/runtime.ts, requireProperty and
      # requiredValidator, at aws/aws-cdk@68b2516c).
      #
      # EXEMPTED holds what the corpus proves the sources wrong about: the provider
      # schema of AWS::CloudFormation::Stack requires StackName, and every nested stack
      # the CDK synthesizes (four templates of the sample have one) has no StackName and
      # deploys. Nothing else was exempted.
      class Required < Rule
        rule "V5"

        EXEMPTED = { "AWS::CloudFormation::Stack" => %w[StackName] }.freeze

        def call(context)
          issues = []
          Scans::Resources.typed(context) do |_name, _body, path, type, properties|
            skipped = EXEMPTED.fetch(type.name, [])
            SchemaWalk.each_node(type, properties, path) do |walk_type, node, hash, at|
              node.required.each do |required|
                next if skipped.include?(required) && walk_type.equal?(type)
                next if walk_type.read_only.include?(required) || present?(hash, node, required)

                issues << missing(at + [ required ], required, Template.node_name(walk_type, node))
              end
            end
            SchemaWalk.each_value(type, properties, path) do |walk_type, _node, property, value, at|
              SchemaWalk.each_nil_element(walk_type, property, value, at) do |definition, element|
                definition.required.each do |required|
                  issues << missing(element + [ required ], required, Template.node_name(walk_type, definition))
                end
              end
            end
          end
          issues
        end

        private

        def present?(hash, node, name)
          hash.any? { |key, value| !value.nil? && Normalizer.lookup(node, key.to_s)&.name == name }
        end

        def missing(path, name, owner)
          error(path, "the required property #{name} is missing on #{owner}", hint: "add it, as #{name} or in snake_case as #{Template.snake(name)}")
        end
      end

      # V6: a literal has the kind of its property. A number or a boolean in quotes is
      # rule V17's, and a list that is not an array is rule V7's. An intrinsic is never
      # wrong: it stands for a value only CloudFormation will know.
      #
      # F3012 of the CDK's engine: property type mismatch.
      class Kinds < Rule
        rule "V6"

        def call(context)
          issues = []
          Scans::Leaves.each(context) do |_type, _node, property, kind, value, at|
            next if kind == :list || Scans::Kind.check(kind, value) != :wrong

            issues << error(at, "#{Template.show(value)} is written where #{Scans::Kind.article(kind)} is expected (#{property.name})",
              hint: Scans::Kind.hint(kind))
          end
          issues
        end
      end

      # V7: a list property holds an array. Where the type allows each element once, an
      # element written twice is a warning.
      #
      # The CDK's own validator says `"CorsRules!" should be a list` (core/lib/runtime.ts,
      # listValidator); F3037 and W9007 of its engine cover duplicates.
      class Lists < Rule
        rule "V7"

        def call(context)
          issues = []
          Scans::Leaves.each(context) do |type, node, property, kind, value, at|
            next unless kind == :list

            if value.is_a?(Array)
              next unless property.unique_items == true

              duplicates(value).each do |item, count|
                issues << warning(at, "#{Template.show(item)} is written #{count} times in #{property.name}, which takes each value once",
                  hint: "remove the duplicates: AWS rejects this list")
              end
            else
              issues << error(at, "#{Template.show(value)} is written where a list is expected (#{Template.node_name(type, node)}.#{property.name})",
                hint: "write an Array, as [ \"GET\", \"POST\" ]")
            end
          end
          issues
        end

        private

        # [ item, how often ] for every literal and every object written more than once,
        # in the order of their first appearance. Intrinsics are left out.
        def duplicates(list)
          seen = Hash.new(0)
          list.each { |item| seen[item] += 1 unless Template.intrinsic?(item) }
          seen.select { |_item, count| count > 1 }.to_a
        end
      end

      # V12: the quotas of a template, and the lengths of its names.
      #
      # The numbers are the CDK's engine's (aws-cloudformation/cloudformation-validate@
      # 55ff54b6, src/cel-engine/src/rules/structure.rs: F0007, F0003, F0004, F0008 and
      # F0009 for the counts; F2011, F6011 and F7002 for 255 characters; F0011 for the
      # Description). Two differences, both from architecture §6: the Description is
      # measured in bytes, as AWS states the quota and as §6 says, where the engine counts
      # characters; and the 255 apply to the names of conditions and of resources too.
      class Quotas < Rule
        rule "V12"

        LIMITS = { "Resources" => 500, "Parameters" => 200, "Outputs" => 200, "Mappings" => 200, "Conditions" => 200 }.freeze
        NAMED = %w[Parameters Mappings Conditions Resources Outputs].freeze
        NAME_LENGTH = 255
        DESCRIPTION_BYTES = 1024

        def call(context)
          template = context.template
          return [] unless template.is_a?(Hash)

          issues = LIMITS.filter_map do |section, limit|
            count = Template.section(template, section).size
            next unless count > limit

            error([ section ], "the template declares #{count} #{section.downcase}, and CloudFormation accepts at most #{limit} of them",
              hint: "split the stack")
          end
          NAMED.each do |section|
            Template.section(template, section).each_key do |name|
              next unless name.to_s.length > NAME_LENGTH

              issues << error([ section, name.to_s ], "the logical ID is #{name.to_s.length} characters long; CloudFormation accepts at most #{NAME_LENGTH}",
                hint: "shorten it")
            end
          end
          description = template["Description"]
          if description.is_a?(String) && description.bytesize > DESCRIPTION_BYTES
            issues << error([ "Description" ], "the Description is #{description.bytesize} bytes long; CloudFormation accepts at most #{DESCRIPTION_BYTES}",
              hint: "shorten it, and put the rest where a reader will find it")
          end
          issues
        end
      end

      # V13: a stack name starts with a letter, goes on with letters, digits and hyphens,
      # and is at most 128 characters long. The pipeline runs its own V13 from the tree
      # (synth/rules.rb, over Core::Stack::NAME_PATTERN, which this is a copy of: core is
      # not a dependency of the validation component). A template with no stack behind it
      # has nothing to check.
      class StackName < Rule
        rule "V13"

        NAME = /\A[A-Za-z][A-Za-z0-9-]*\z/
        MAX_NAME_LENGTH = 128

        def call(context)
          stack = context.stack
          name = stack.respond_to?(:stack_name) ? stack.stack_name : nil
          return [] if name.nil? || (name.is_a?(String) && name.match?(NAME) && name.length <= MAX_NAME_LENGTH)

          [
            error("Stack", "the stack name #{name.inspect} is not valid: it must start with a letter, go on with letters, digits and hyphens, " \
                          "and be at most #{MAX_NAME_LENGTH} characters long",
              hint: "a stack's name is the prefix of App.new(stack_name_prefix:) followed by its id")
          ]
        end
      end

      # V16: DeletionPolicy is one of Delete, Retain, RetainExceptOnCreate and Snapshot;
      # UpdateReplacePolicy is one of Delete, Retain and Snapshot. An intrinsic may stand
      # for a policy, as the CDK's include accepts (test-templates/intrinsic-deletion-
      # policy.json and intrinsic-deletion-policy-ref.json); the literal branches of an
      # Fn::If are each checked, as the engine checks every scenario a policy can take.
      #
      # F3016 and F0018 of the CDK's engine.
      class Policies < Rule
        rule "V16"

        ALLOWED = { "DeletionPolicy" => %w[Delete Retain RetainExceptOnCreate Snapshot], "UpdateReplacePolicy" => %w[Delete Retain Snapshot] }.freeze

        def call(context)
          issues = []
          Scans::Resources.each(context) do |_name, body, path|
            ALLOWED.each do |attribute, allowed|
              next unless body.key?(attribute)

              wrong(body[attribute], allowed, []) do |value, at|
                issues << error(path + [ attribute, *at ], "#{attribute} #{Template.show(value)} is not one of #{Text.list(allowed)}",
                  hint: attribute == "UpdateReplacePolicy" ? "CloudFormation takes no RetainExceptOnCreate here: write Retain" : "write the name as it is, or pass deletion_policy: as a symbol")
              end
            end
          end
          issues
        end

        private

        # Yields each literal a policy attribute holds that CloudFormation takes no, with
        # the segments that lead to it inside an Fn::If. An intrinsic that is no Fn::If
        # yields nothing: what it resolves to is not known here.
        def wrong(value, allowed, at)
          if Template.function?(value, "Fn::If") && value["Fn::If"].is_a?(Array) && value["Fn::If"].size == 3
            value["Fn::If"][1, 2].each_with_index do |branch, index|
              wrong(branch, allowed, at + [ "Fn::If", "[#{index + 1}]" ]) { |found, where| yield found, where }
            end
          elsif !Template.intrinsic?(value) && !(value.is_a?(String) && allowed.include?(value))
            yield value, at
          end
        end
      end

      # V17: a number or a boolean written as a string, where the schema says a number or
      # a boolean. The CDK's include accepts it and converts it (cloudformation-include/
      # test/valid-templates.test.ts: "accepts strings for properties with type number");
      # here it is an error with the hint, by architecture §21.
      class QuotedValues < Rule
        rule "V17"

        def call(context)
          issues = []
          Scans::Leaves.each(context) do |_type, _node, property, kind, value, at|
            outcome = Scans::Kind.check(kind, value)
            next unless outcome == :string_for_number || outcome == :string_for_boolean

            hint = outcome == :string_for_number ? "drop the quotes: write #{value.strip}" : "drop the quotes: write #{value}"
            issues << error(at, "#{Template.show(value)} is written where #{Scans::Kind.article(kind)} is expected (#{property.name})", hint:)
          end
          issues
        end
      end

      # V18: a literal string is among the values the source lists for the property, in a
      # list or a map element as much as at the top. A number or a boolean is not
      # checked: CloudFormation takes it as its text, as the CDK's include does
      # (test-templates/boolean-for-string.json and number-for-string.json are in its
      # valid set).
      #
      # W3030 of the CDK's engine (a warning there; an error here, by architecture §6).
      class AllowedValues < Rule
        rule "V18"

        STRUCTURAL = %i[list map nested json].freeze

        def call(context)
          issues = []
          Scans::Leaves.each(context) do |_type, _node, property, kind, value, at|
            values = property.allowed_values
            next if values.nil? || values.empty? || STRUCTURAL.include?(kind) || !value.is_a?(String)
            next unless Scans::Kind.check(kind, value) == :ok
            next if values.include?(value)

            issues << error(at, "#{Template.show(value)} is not one of the values #{property.name} takes: #{Text.list(values)}",
              hint: "write one of them, exactly as AWS spells it")
          end
          issues
        end
      end

      # V19: a literal string matches the pattern the source has for the property. A
      # pattern is not anchored by JSON Schema, and is not here. A pattern Ruby cannot
      # read is not checked.
      #
      # F3031 of the CDK's engine (fatal there; a warning here, by architecture §6).
      class Patterns < Rule
        rule "V19"

        # The patterns of the model, compiled once: a Regexp, or false for one Ruby cannot read.
        COMPILED = {}

        def call(context)
          issues = []
          Scans::Leaves.each(context) do |type, _node, property, kind, value, at|
            next unless kind == :string && value.is_a?(String) && property.pattern

            regex = compiled(property.pattern)
            next if !regex || regex.match?(value)

            issues << warning(at, "#{Template.show(value)} does not match the pattern #{property.name} is documented with: #{property.pattern}",
              hint: type.documentation_url ? "see #{type.documentation_url}" : "check the value against the documentation of the type")
          end
          issues
        end

        private

        def compiled(pattern)
          COMPILED.fetch(pattern) { COMPILED[pattern] = readable(pattern) }
        end

        # The source's patterns are JavaScript's; a few use syntax Ruby has no reading of.
        # Ruby warns on each compile about the `-` AWS leaves unescaped inside character
        # classes — the pattern is theirs, so the warning is silenced here, once, and
        # the rule's own reading of a pattern it cannot compile is `false`.
        def readable(pattern)
          saved = $stderr
          $stderr = File.open(File::NULL, "w")
          Regexp.new(pattern)
        rescue RegexpError, SyntaxError
          false
        ensure
          $stderr.close unless $stderr.equal?(saved)
          $stderr = saved
        end
      end
    end
  end
end
