# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# The pipeline of architecture §5: the phases in their order, what each one
# sees, and how a later component adds a normalizer or validators to it
# without the pipeline changing.
class SynthPipelineTest < CoreHelpers::TestCase
  Synth = RubyCdk::Synth

  def setup
    super
    @log = []
    @normalizers = []
    @validators = []
  end

  def teardown
    @normalizers.each { |normalizer| Synth.unregister_normalizer(normalizer) }
    @validators.each { |validator| Synth.unregister_validator(validator) }
    super
  end

  # --- the phases

  def test_the_phases_run_in_order_prepare_resolve_normalize_validate_serialize
    stack = prepare_stack
    add_normalizer(capitalizer("first"))
    add_normalizer(capitalizer("second"))
    add_validator(issue_finder("rule-a") { |_| [] })
    add_validator(issue_finder("rule-b") { |_| [] })

    result = Synth.run(stack)

    assert_equal [ "prepare", "normalize:first", "normalize:second", "validate:rule-a", "validate:rule-b" ], @log
    assert_same stack, result.stack
    assert_equal "UPCASE", result.template["Resources"]["Prepared"]["Properties"]["Key"]
    assert_equal result.bytes, RubyCdk::Synth::Serializer.call(result.template)
    assert_empty result.issues
  end

  def test_prepare_runs_before_resolve_so_what_a_hook_adds_is_in_the_template
    stack = prepare_stack
    seen = []
    add_validator(->(context) { seen << context.template["Resources"].keys; [] })

    assert_equal [ "Early" ], stack.resources.map(&:logical_id)
    result = Synth.run(stack)

    assert_equal [ [ "Early", "Prepared" ] ], seen
    assert_equal [ "Early", "Prepared" ], stack.resources.map(&:logical_id)
    assert_equal [ "Early", "Prepared" ], result.template["Resources"].keys
  end

  def test_resolve_runs_before_normalize_so_a_normalizer_sees_only_plain_values
    stack = build_stack { resource("A", "AWS::SNS::Topic", DisplayName: Lazy.new { "later" }, Fifo: :yes) }
    seen = []
    add_normalizer(->(context) { seen << context.template["Resources"]["A"]["Properties"]; context.template })

    Synth.run(stack)

    assert_equal [ { "DisplayName" => "later", "Fifo" => "yes" } ], seen
  end

  # --- normalizers

  def test_a_normalizer_answers_a_new_template_and_leaves_the_one_it_was_given_alone
    stack = build_stack { resource("A", "AWS::SNS::Topic", DisplayName: "x") }
    given = []
    add_normalizer(lambda { |context|
      given << context.template
      { "AWSTemplateFormatVersion" => context.template["AWSTemplateFormatVersion"], "Resources" => { "A" => { "Type" => "Normalized" } } }
    })

    result = Synth.run(stack)

    assert_equal({ "AWSTemplateFormatVersion" => "2010-09-09", "Resources" => { "A" => { "Type" => "Normalized" } } }, result.template)
    assert_equal "Normalized", JSON.parse(result.bytes)["Resources"]["A"]["Type"]
    assert_equal({ "AWSTemplateFormatVersion" => "2010-09-09", "Resources" => { "A" => { "Type" => "AWS::SNS::Topic", "Properties" => { "DisplayName" => "x" } } } },
      given.first)
    assert_not_same given.first, result.template
  end

  def test_normalizers_run_in_the_order_they_were_registered_and_each_sees_what_the_one_before_answered
    stack = build_stack { resource("A", "AWS::SNS::Topic") }
    add_normalizer(prefixer("Step1"))
    add_normalizer(prefixer("Step2"))

    result = Synth.run(stack)

    assert_equal({ "AWSTemplateFormatVersion" => "2010-09-09", "Resources" => { "A" => { "Type" => "Step1:Step2:AWS::SNS::Topic" } } }, result.template)
    assert_equal [ "Step1", "Step2" ], @log
  end

  def test_a_normalizer_that_does_not_answer_a_hash_is_an_error
    add_normalizer(->(_context) { "not a template" })

    error = assert_raises(RubyCdk::Error) { Synth.run(build_stack) }

    assert_match(/returned a String, and a normalizer returns the template as a Hash/, error.message)
  end

  # --- validators

  def test_a_validator_sees_exactly_the_bytes_that_would_be_written
    stack = build_stack { resource("A", "AWS::SNS::Topic", DisplayName: "x") }
    add_normalizer(capitalizer("n"))
    seen = []
    add_validator(->(context) { seen << [ context.stack, context.template, RubyCdk::Synth::Serializer.call(context.template) ]; [] })

    result = Synth.run(stack)

    assert_same stack, seen.first[0]
    assert_same result.template, seen.first[1]
    assert_equal result.bytes, seen.first[2]
  end

  def test_every_issue_of_every_validator_is_reported_in_one_error_with_the_value_model_s
    stack = build_stack { resource("A", "AWS::SNS::Topic", DisplayName: Time.now) }
    add_validator(issue_finder("VA") { |context| [ issue("VA", "#{context.stack.stack_name}:one"), issue("VA", "two") ] })
    add_validator(issue_finder("VB") { |_| [ issue("VB", "three") ] })

    result = Synth.run(stack)

    assert_equal %w[ V0 VA VA VB ], result.issues.map(&:rule)
    assert_equal [ "Resources.A.Properties.DisplayName", "blog:one", "two", "three" ], result.issues.map(&:path)
    assert_predicate result.issues, :frozen?

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal result.issues, error.issues
    assert_equal 4, error.message.lines.length
  end

  def test_a_validator_sees_what_was_found_before_it
    stack = build_stack { resource("A", "AWS::SNS::Topic", DisplayName: Time.now) }
    seen = []
    add_validator(issue_finder("VA") { |_| [ issue("VA", "early") ] })
    add_validator(->(context) { seen << context.issues; [] })

    Synth.run(stack)

    assert_equal %w[ V0 VA ], seen.first.map(&:rule)
    assert_predicate seen.first, :frozen?
  end

  def test_validators_run_in_the_order_they_were_registered
    add_validator(issue_finder("one") { |_| [] })
    add_validator(issue_finder("two") { |_| [] })

    Synth.run(build_stack)

    assert_equal [ "validate:one", "validate:two" ], @log
  end

  def test_a_validator_may_answer_nothing
    add_validator(->(_context) { nil })

    assert_empty Synth.run(build_stack).issues
  end

  # --- run and synthesize

  def test_run_never_raises_and_synthesize_raises_once_with_every_issue
    stack = build_stack do
      resource("my_table", "AWS::DynamoDB::Table", DisplayName: Object.new)
      output("bad_output", value: 1)
    end

    result = Synth.run(stack)

    assert_equal %w[ V0 V2 V2 ], result.issues.map(&:rule)
    assert_kind_of Hash, result.template
    assert_kind_of String, result.bytes

    error = assert_raises(RubyCdk::ValidationError) { Synth.synthesize(stack) }

    assert_equal 3, error.issues.length

    clean = Synth.synthesize(build_stack { resource("Table", "AWS::DynamoDB::Table") })

    assert_empty clean.issues
    assert_equal [ "Table" ], clean.template["Resources"].keys
  end

  def test_to_template_answers_the_validated_template_and_synthesizes_again_the_same_way
    stack = prepare_stack
    add_normalizer(capitalizer("n"))

    first = stack.to_template
    second = stack.to_template

    assert_equal first, second
    assert_not_same first, second
    assert_equal [ "prepare", "normalize:n", "normalize:n" ], @log
    assert_equal [ "Early", "Prepared" ], stack.resources.map(&:logical_id)
  end

  def test_a_stack_with_nothing_in_it_synthesizes_to_an_empty_template
    result = Synth.run(build_stack)

    assert_equal({}, result.template)
    assert_equal "{}\n", result.bytes
  end

  def test_a_lazy_is_evaluated_once_across_two_syntheses
    calls = 0
    stack = build_stack { resource("A", "AWS::SNS::Topic", DisplayName: Lazy.new { calls += 1 }) }

    stack.to_template
    stack.to_template

    assert_equal 1, calls
  end

  # --- the registry

  def test_the_rules_of_this_component_are_registered_like_any_other_validator
    assert_includes Synth.validators.map(&:class), Synth::Rules::LogicalIds
    assert_includes Synth.validators.map(&:class), Synth::Rules::StackName
    assert_empty Synth.normalizers
    assert_empty Synth.manifest_fact_keys
  end

  def test_unregister_takes_a_normalizer_or_a_validator_out
    normalizer = capitalizer("n")
    validator = issue_finder("v") { |_| [ issue("VX", "x") ] }
    add_normalizer(normalizer)
    add_validator(validator)

    Synth.unregister_normalizer(normalizer)
    Synth.unregister_validator(validator)

    assert_empty Synth.normalizers
    refute_includes Synth.validators, validator
    assert_equal "x", build_stack { resource("A", "AWS::SNS::Topic", DisplayName: "x") }.to_template["Resources"]["A"]["Properties"]["DisplayName"]
  end

  def test_registering_something_that_does_not_answer_call_is_an_argument_error
    assert_raises(ArgumentError) { Synth.register_normalizer(Object.new) }
    assert_raises(ArgumentError) { Synth.register_validator("not a validator") }
    assert_raises(ArgumentError) { Synth.register_manifest_fact("schema_version") }
    assert_raises(ArgumentError) { Synth.register_manifest_fact("") { 1 } }
    assert_raises(ArgumentError) { Synth.register_entry_fact("assets") }
  end

  def test_a_lambda_is_a_normalizer_or_a_validator
    validator = ->(_context) { [] }

    Synth.register_validator(validator)

    assert_kind_of Proc, Synth.validators.last

    Synth.unregister_validator(validator)
  end

  # --- determinism

  def test_synthesizing_the_same_app_twice_gives_identical_bytes_and_writes_nothing_the_second_time
    app = two_stack_app
    manifest = app.synth
    files = [ "demo-blog.template.json", "demo-audit.template.json", "manifest.json" ].map { |name| File.join(manifest.out_dir, name) }
    written = files.to_h { |path| [ path, [ File.binread(path), File.mtime(path) ] ] }

    again = app.synth

    assert_equal manifest.bytes, again.bytes
    assert_equal manifest.entries.map(&:template_hash), again.entries.map(&:template_hash)
    written.each do |path, (bytes, time)|
      assert_equal bytes, File.binread(path), File.basename(path)
      assert_equal time, File.mtime(path), "#{File.basename(path)} was written again"
    end
  end

  def test_two_apps_built_the_same_way_give_identical_bytes
    build = -> { Synth::Manifest.build(two_stack_app, two_stack_app.stacks.map { |stack| Synth.run(stack) }).bytes }

    assert_equal build.call, build.call
  end

  def test_template_bytes_do_not_depend_on_when_or_where
    template = -> { Synth.run(build_stack { resource("Table", "AWS::DynamoDB::Table", TableName: unique_name("data")) }).bytes }

    assert_equal template.call, Dir.chdir(dir) { template.call }
  end

  private

  # A stack whose prepare hook adds a resource and says so in the log.
  def prepare_stack
    log = @log
    klass = Class.new(RubyCdk::Stack) do
      define_method(:build) { resource("Early", "AWS::SNS::Topic") }
      define_method(:prepare) do
        log << "prepare"
        resource("Prepared", "AWS::SNS::Topic", Key: "upcase")
      end
    end
    klass.new(build_app(env: TEST_ENV), "blog")
  end

  def add_normalizer(normalizer)
    Synth.register_normalizer(normalizer)
    @normalizers << normalizer
  end

  def add_validator(validator)
    Synth.register_validator(validator)
    @validators << validator
  end

  # A normalizer that notes it ran and writes every string property in capitals.
  def capitalizer(name)
    lambda { |context|
      @log << "normalize:#{name}"
      context.template.merge("Resources" => context.template["Resources"].transform_values do |body|
        next body unless body["Properties"]

        body.merge("Properties" => body["Properties"].transform_values { |value| value.is_a?(String) ? value.upcase : value })
      end)
    }
  end

  # A normalizer that puts its name in front of the type of every resource.
  def prefixer(name)
    lambda { |context|
      @log << name
      context.template.merge("Resources" => context.template["Resources"].transform_values { |body| body.merge("Type" => "#{name}:#{body["Type"]}") })
    }
  end

  # A validator that notes it ran and answers what the block says.
  def issue_finder(name, &answer)
    lambda { |context|
      @log << "validate:#{name}"
      answer.call(context)
    }
  end

  def issue(rule, path)
    RubyCdk::Issue.new(rule:, path:, message: "found by #{rule}", hint: nil)
  end

  def two_stack_app
    app = build_app(env: TEST_ENV, stack_name_prefix: "demo-")
    stack_class do
      table = resource("Table", "AWS::DynamoDB::Table", TableName: unique_name("data"))
      export("TableName", value: Fn.ref(table))
    end.new(app, "blog")
    stack_class do
      resource("Vpc", "AWS::EC2::VPC", CidrBlock: "10.0.0.0/16")
      parameter("Stage", type: "String")
    end.new(app, "audit")
    app
  end
end
