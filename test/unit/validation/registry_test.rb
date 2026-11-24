# frozen_string_literal: true

require_relative "support"

# The registry the pipeline learns the component through: the two lists, the options,
# and the check docs/07-testing.md §10 asks of every rule, that its failing case fails
# when the rule is off.
class ValidationRegistryTest < Minitest::Test
  include ValidationCase

  # The failing fixture of every rule, by id. V4 has none: no type of the model names
  # two properties the same way without regard to case and underscores, so no template
  # can make it fire; test_v4_cannot_fire_on_this_model proves that.
  FAILING = {
    "V1" => "v1-no-type",
    "V2" => "v2-underscore-id",
    "V3" => "v3-unresolvable-snake",
    "V5" => "v5-missing-top",
    "V6" => "v6-wrong-kind",
    "V7" => "v7-not-a-list",
    "V8" => "v8-ref-missing",
    "V9" => "v9-attribute-missing",
    "V10" => "v10-sub-missing",
    "V11" => "v11-find-in-map",
    "V12" => "v12-name-too-long",
    "V13" => nil, # built below: a name needs no fixture
    "V14" => "v14-cycle",
    "V15" => "v15-stateful-delete",
    "V16" => "v16-bad-policies",
    "V17" => "v17-string-for-number",
    "V18" => "v18-bad-value",
    "V19" => "v19-pattern",
    "V20" => "v20-empty-sub",
    "V21" => "v21-getatt-no-dot",
    "V22" => "v22-getatt-in-conditions",
    "V23" => "v23-intrinsic-policy"
  }.freeze

  def test_every_rule_is_registered_once_under_its_number
    assert_equal (1..23).map { |number| "V#{number}" }, RubyCdk::Validation.rule_ids
    assert_equal %w[V2 V13], RubyCdk::Validation::PIPELINE_RULES
  end

  def test_the_normalizers_are_one_callable
    normalizers = RubyCdk::Validation.normalizers

    assert_equal 1, normalizers.length
    normalizers.each { |normalizer| assert_respond_to normalizer, :call }
  end

  def test_the_validators_are_callables_that_answer_issues
    RubyCdk::Validation.validators(stateful_types: ValidationCase::STATEFUL_TYPES).each do |validator|
      assert_respond_to validator, :call
      assert_kind_of Array, validator.call(empty_context)
    end
  end

  def test_the_list_leaves_the_rules_the_pipeline_runs_itself_out
    # With the stateful list given, V15 is built: the list is then 23 rules less V2 and
    # V13, which the pipeline runs from the tree.
    assert_equal RubyCdk::Validation::RULES.size - 2,
      RubyCdk::Validation.validators(stateful_types: ValidationCase::STATEFUL_TYPES).length
    # Without it, V15 is not built; a disabled rule is not built either.
    assert_equal RubyCdk::Validation::RULES.size - 1,
      RubyCdk::Validation.validators(pipeline_rules: false, disabled: [ "V15" ]).length
  end

  def test_the_list_carries_everything_when_the_pipeline_is_not_running
    validators = RubyCdk::Validation.validators(pipeline_rules: false, stateful_types: ValidationCase::STATEFUL_TYPES)

    assert_equal RubyCdk::Validation::RULES.size, validators.length
  end

  def test_strict_types_makes_the_unknown_type_an_error
    with_strict = RubyCdk::Validation.validators(strict_types: true, pipeline_rules: false, disabled: [ "V15" ])
    without = RubyCdk::Validation.validators(pipeline_rules: false, disabled: [ "V15" ])

    context = RubyCdk::Validation::Context.new(stack: nil, template: fixture("v1-unknown-type"), issues: [])
    assert_empty with_strict.first.call(context).select { |issue| RubyCdk::Validation.warning?(issue) }
    assert_empty without.first.call(context)
    refute_empty with_strict.first.call(context)
  end

  def test_warnings_are_answered_apart_from_the_errors
    options = { pipeline_rules: false, stateful_types: ValidationCase::STATEFUL_TYPES }
    context = RubyCdk::Validation::Context.new(stack: nil, template: fixture("v15-stateful-delete"), issues: [])

    # By default the validators answer the errors alone: the template has only a warning.
    assert_empty RubyCdk::Validation.validators(**options).flat_map { |validator| validator.call(context) }

    with_warnings = RubyCdk::Validation.validators(**options, warnings: true)
    answered = with_warnings.flat_map { |validator| validator.call(context) }
    assert_equal 1, answered.length
    assert RubyCdk::Validation.warning?(answered.first)

    only_warnings = RubyCdk::Validation.validators(**options, warnings: :only)
    assert_equal 1, only_warnings.flat_map { |validator| validator.call(context) }.length
  end

  def test_an_unknown_rule_is_refused
    assert_raises(ArgumentError) { RubyCdk::Validation.validators(disabled: [ "V99" ]) }
    assert_raises(ArgumentError) { RubyCdk::Validation.rule("V99") }
    assert_raises(ArgumentError) { RubyCdk::Validation.rule("V1", nonsense: true) }
  end

  def test_a_stateful_rule_without_the_list_is_not_built_and_one_built_without_it_is_refused
    assert_empty RubyCdk::Validation.validators.select { |validator| validator.call(empty_context).any? { |issue| issue.rule == "V15" } }
    assert_raises(ArgumentError) { RubyCdk::Validation.rule("V15") }
  end

  def test_v4_cannot_fire_on_this_model
    # The proof the exemption of the mutation test rests on: no node of the model names
    # two properties the same way without regard to case and underscores, so no template
    # can make V4 fire, and there is no failing case to mutate.
    RubyCdk::Schema.types.each do |type|
      schema = RubyCdk::Schema.type(type)
      nodes = [ schema, *schema.definitions.values ]
      nodes.each do |node|
        folded = node.properties.keys.map { |name| RubyCdk::Validation::Template.fold(name) }
        assert_equal folded.size, folded.uniq.size, "#{type}.#{node.name} has two properties one folded name"
      end
    end
  end

  def test_every_rule_fails_its_case_only_while_it_is_registered
    checked = []
    without_case = []

    RubyCdk::Validation::RULES.each_key do |id|
      template =
        if id == "V13"
          fixture("pass-minimal")
        else
          name = FAILING[id]
          if name.nil?
            without_case << id
            next
          end
          fixture(name)
        end
      options = { pipeline_rules: false, stateful_types: ValidationCase::STATEFUL_TYPES, warnings: true }
      options[:stack_name] = "1blog" if id == "V13"

      on = report_for(template, **options).of_rule(id)
      refute_empty on, "#{id} does not fire on its failing case"
      off = report_for(template, **options, disabled: [ id ]).of_rule(id)
      assert_empty off, "#{id} fires while it is disabled"

      checked << id
    end

    assert_equal [ "V4" ], without_case, "every rule without a failing case must be here, with the proof in its own test"
    assert_equal RubyCdk::Validation::RULES.keys - [ "V4" ], checked.sort_by { |id| id[1..].to_i }
  end

  private

  def empty_context
    RubyCdk::Validation::Context.new(stack: nil, template: {}, issues: [])
  end
end
