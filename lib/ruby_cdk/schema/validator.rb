# frozen_string_literal: true

# The validation component: the normalizer and the rules of architecture §6, over a
# template as a plain Hash and on the schema model. It depends on nothing above it. The
# pipeline learns it only through what is registered with it, and the umbrella does the
# registering:
#
#   RubyCdk::Synth.register_normalizer(RubyCdk::Validation.normalizers.first)
#   RubyCdk::Validation.validators.each { |validator| RubyCdk::Synth.register_validator(validator) }
#
# A normalizer answers call(context) with a new template, its keys resolved. A validator
# answers call(context) with an Array of RubyCdk::Issue. The context is anything that
# answers stack, template and issues.
require_relative "normalizer"
require_relative "validator/rule"
require_relative "validator/template"
require_relative "validator/walk"
require_relative "validator/scans"
require_relative "validator/structure"
require_relative "validator/refs"
require_relative "validator/template_rules"
require_relative "validator/policies"
require_relative "validator/corpus_check"
require_relative "validator/report"

module RubyCdk
  # What CloudFormation would reject, found before a template leaves the machine.
  module Validation
    # Every rule, by its id, in the order they run: the order of architecture §6.
    RULES = {
      "V1" => Rules::KnownTypes,
      "V2" => Rules::LogicalIds,
      "V3" => Rules::Properties,
      "V4" => Rules::AmbiguousProperties,
      "V5" => Rules::Required,
      "V6" => Rules::Kinds,
      "V7" => Rules::Lists,
      "V8" => Rules::References,
      "V9" => Rules::Attributes,
      "V10" => Rules::Substitutions,
      "V11" => Rules::Targets,
      "V12" => Rules::Quotas,
      "V13" => Rules::StackName,
      "V14" => Rules::Cycles,
      "V15" => Rules::StatefulDeletion,
      "V16" => Rules::Policies,
      "V17" => Rules::QuotedValues,
      "V18" => Rules::AllowedValues,
      "V19" => Rules::Patterns,
      "V20" => Rules::EmptySubstitution,
      "V21" => Rules::ShortFormGetAtt,
      "V22" => Rules::NoGetAttInConditions,
      "V23" => Rules::PolicyIntrinsics
    }.freeze

    # The rules the pipeline runs itself, from the tree, where the tree sees more than a
    # template does (synth/rules.rb): V2 over the logical IDs of the whole stack, V13 over
    # the stack's name. validators leaves them out unless told that it is the only check.
    PIPELINE_RULES = %w[V2 V13].freeze

    # The one rule that needs something this component does not own: the list of stateful
    # types (core/stateful.rb), given as stateful_types.
    STATEFUL_RULE = "V15"

    # How a validator answers a warning. The pipeline fails a synthesis on every Issue it
    # is handed, so by default the validators hand it the errors alone. A pipeline that
    # keeps warnings apart asks for warnings: true and sorts them with
    # Validation.warning?; until then, warnings: :only is the separate list of validators
    # that answer the warnings and nothing else.
    WARNINGS = %i[only].freeze

    # What the rules receive, as the pipeline gives it to them: the stack (nil when the
    # template has none), the template, and what the phases before found.
    Context = Data.define(:stack, :template, :issues)

    # What stands for a stack when there is no tree: a name, and nothing else.
    NamedStack = Data.define(:stack_name)

    class << self
      # The ids of every rule, in the order they run.
      def rule_ids
        RULES.keys
      end

      # One rule on its own, built with what it takes: strict_types: for V1, types: for V15.
      def rule(id, **options)
        build(id, **options)
      end

      # The normalizers, in the order they run: one, which resolves the keys.
      def normalizers(**_options)
        [ Normalizer ]
      end

      # The validators, in the order they run, each answering call(context) with its issues.
      #
      #   strict_types:    V1 makes an unknown type an error, not a warning.
      #   disabled:        the ids of rules to leave out.
      #   pipeline_rules:  false when the pipeline's own V2 and V13 are not running, so
      #                    that this list must carry them (a template with no tree).
      #   stateful_types:  the types architecture §7 retains; V15 is built only with it.
      #   warnings:        true to answer warnings with the errors; :only to answer the
      #                    warnings alone; the default answers the errors alone.
      def validators(strict_types: false, disabled: [], pipeline_rules: true, stateful_types: nil, warnings: false)
        raise ArgumentError, "warnings: takes true, false or :only, got #{warnings.inspect}" unless warnings == true || warnings == false || WARNINGS.include?(warnings)

        off = Array(disabled).map(&:to_s)
        unknown = off - RULES.keys
        raise ArgumentError, "no rule #{unknown.join(", ").inspect}: the rules are #{RULES.keys.join(", ")}" unless unknown.empty?

        RULES.filter_map do |id, klass|
          next if off.include?(id) || (pipeline_rules && PIPELINE_RULES.include?(id)) || (id == STATEFUL_RULE && stateful_types.nil?)

          klass.new(**options_of(id, strict_types, stateful_types))
        end.map { |rule| answering(rule, warnings) }
      end

      # One template, normalized and validated, with nothing left out: for a command
      # that reports, and for a template that has no tree behind it. stack_name is the
      # name of the stack the template belongs to, which V13 needs.
      def validate(template, stack_name: nil, **options)
        normalized = Normalizer.normalize(template)
        context = Context.new(stack: stack_name && NamedStack.new(stack_name.to_s), template: normalized, issues: [])
        issues = validators(**{ pipeline_rules: false, warnings: true }.merge(options)).flat_map { |validator| validator.call(context) }
        Report.new(issues, normalized)
      end

      private

      def build(id, strict_types: false, types: nil, **options)
        raise ArgumentError, "rule #{id} takes no #{options.keys.join(", ")}:" unless options.empty?
        raise ArgumentError, "rule V15 needs types:, the stateful types of architecture §7" if id.to_s == STATEFUL_RULE && types.nil?

        klass = RULES[id.to_s] or raise ArgumentError, "no rule #{id.inspect}: the rules are #{RULES.keys.join(", ")}"
        klass.new(**options_of(id.to_s, strict_types, types))
      end

      def options_of(id, strict_types, stateful_types)
        case id
        when "V1" then { strict_types: }
        when STATEFUL_RULE then { types: stateful_types }
        else {}
        end
      end

      # The callable the pipeline registers: the rule, answering only what was asked for.
      def answering(rule, warnings)
        case warnings
        when false
          ->(context) { rule.call(context).reject { |issue| Validation.warning?(issue) } }
        when :only
          ->(context) { rule.call(context).select { |issue| Validation.warning?(issue) } }
        else
          ->(context) { rule.call(context) }
        end
      end
    end
  end
end
