# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/test"

# This tool's own tests of RubyCdk::Test::Template: how a template is built here,
# and get(path), neither of which the CDK has; and the paths its tests leave. The
# CDK's own tests are under test/cdk/assertions.
class TestKitTemplateTest < Minitest::Test
  # RubyCdk::Test, by a short name.
  T = RubyCdk::Test

  # Anything with a to_template method, as a Ruby stack has.
  StackLike = Struct.new(:to_template)

  BUCKET = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" } } }.freeze

  CYCLE = {
    "Resources" => {
      "Res1" => { "Type" => "Foo", "Properties" => { "Thing" => { "Ref" => "Res2" } } },
      "Res2" => { "Type" => "Foo", "DependsOn" => [ "Res1" ] }
    }
  }.freeze

  TEMPLATE = {
    "Resources" => {
      "Fn" => {
        "Type" => "AWS::Lambda::Function",
        "Properties" => {
          "Timeout" => 30,
          "Runtime" => "ruby4.0",
          "Layers" => [ "a", "b" ],
          "VpcConfig" => nil
        }
      }
    },
    "a.b" => "a key with a dot"
  }.freeze

  VERSIONED_BUCKET = {
    "Type" => "AWS::S3::Bucket",
    "Properties" => { "VersioningConfiguration" => { "Status" => "Enabled" } }
  }.freeze

  # --- what a template is built from

  def test_a_template_is_built_from_anything_with_a_to_template_method
    assert_equal BUCKET, T.template(StackLike.new(BUCKET)).to_json
  end

  def test_to_template_is_asked_before_the_class_of_the_source_is_looked_at
    stack = Class.new(Hash) do
      def to_template
        BUCKET
      end
    end.new
    stack["Resources"] = {}

    assert_equal BUCKET, T.template(stack).to_json
  end

  def test_to_template_must_return_a_json_object
    error = assert_raises(ArgumentError) { T.template(StackLike.new([ 1 ])) }

    assert_equal "A CloudFormation template is a JSON object, got array", error.message
  end

  def test_a_template_is_built_from_a_json_string
    assert_equal BUCKET, T.template(BUCKET.to_json).to_json
    assert_equal BUCKET, T.from_string(BUCKET.to_json).to_json
    assert_equal BUCKET, T::Template.from_string(BUCKET.to_json).to_json
  end

  def test_a_template_is_built_from_a_hash
    assert_equal BUCKET, T.from_json(BUCKET).to_json
    assert_equal BUCKET, T::Template.from_json(BUCKET).to_json
  end

  def test_a_template_that_is_not_a_json_object_is_refused
    [ "5", "[ 1 ]" ].each do |source|
      error = assert_raises(ArgumentError, "#{source.inspect} was accepted") { T.template(source) }

      assert_match(/\AA CloudFormation template is a JSON object, got (array|number)\z/, error.message)
    end
    error = assert_raises(ArgumentError) { T.template([ 1 ]) }

    assert_equal "Expected a template: anything with a to_template method, a Hash or a JSON string, got Array", error.message
  end

  def test_a_source_that_is_none_of_these_is_refused
    [ 5, nil, Object.new ].each do |source|
      error = assert_raises(ArgumentError, "#{source.inspect} was accepted") { T.template(source) }

      assert_equal "Expected a template: anything with a to_template method, a Hash or a JSON string, got #{source.class}",
        error.message
    end
  end

  def test_a_string_that_is_not_json_raises_the_parser_error
    error = assert_raises(JSON::ParserError) { T.from_string("{oops") }

    assert_match(/expected object key/, error.message)
  end

  # --- a Hash written the Ruby way

  def test_a_hash_template_may_be_written_with_symbols
    source = { Resources: { Bucket: { Type: :"AWS::S3::Bucket", Properties: { BucketName: :data } } } }

    assert_equal({ "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "data" } } } },
      T.template(source).to_json)
    assert_equal [ :Resources ], source.keys, "the Hash of the caller was modified"
  end

  def test_a_pattern_may_be_written_with_symbols_too
    template = T.from_json({ "Resources" => { "Bucket" => VERSIONED_BUCKET } })

    template.has_resource_properties("AWS::S3::Bucket", VersioningConfiguration: { Status: "Enabled" })
    template.has_resource("AWS::S3::Bucket", Type: "AWS::S3::Bucket", Properties: T.object_like(VersioningConfiguration: { Status: "Enabled" }))
    template.find_resources("AWS::S3::Bucket", Properties: { VersioningConfiguration: T.object_like(Status: "Enabled") })
    template.template_matches(Resources: { Bucket: { Type: "AWS::S3::Bucket" } })
  end

  def test_a_matcher_inside_a_pattern_written_with_symbols_is_left_alone
    pattern = { VersioningConfiguration: { Status: T.any_value } }

    assert_equal false, T.object_like(pattern).test({ "VersioningConfiguration" => { "Status" => "Enabled" } }).has_failed?
    assert T::Matcher.matcher?(pattern[:VersioningConfiguration][:Status])
    assert_equal [ :VersioningConfiguration ], pattern.keys
  end

  # --- the cyclic check on every way in

  def test_every_way_in_checks_for_a_dependency_cycle_unless_told_not_to
    [ CYCLE, CYCLE.to_json, StackLike.new(CYCLE) ].each do |source|
      assert_thrown(/dependency cycle/) { T.template(source) }
      assert_thrown(/dependency cycle/) { T.template(source, skip_cyclical_dependencies_check: false) }
      T.template(source, skip_cyclical_dependencies_check: true)
      assert_thrown(/dependency cycle/) { T::Template.template(source) }
      T::Template.template(source, skip_cyclical_dependencies_check: true)
    end
    assert_thrown(/dependency cycle/) { T.from_json(CYCLE) }
    T.from_json(CYCLE, skip_cyclical_dependencies_check: true)
    assert_thrown(/dependency cycle/) { T.from_string(CYCLE.to_json) }
    T.from_string(CYCLE.to_json, skip_cyclical_dependencies_check: true)
    assert_thrown(/dependency cycle/) { T::Template.from_json(CYCLE) }
    T::Template.from_json(CYCLE, skip_cyclical_dependencies_check: true)
    assert_thrown(/dependency cycle/) { T::Template.from_string(CYCLE.to_json) }
    T::Template.from_string(CYCLE.to_json, skip_cyclical_dependencies_check: true)
  end

  def test_a_hash_template_may_be_written_without_braces
    resources = BUCKET["Resources"]

    assert_equal BUCKET, T.from_json("Resources" => resources).to_json
    assert_equal BUCKET, T.template("Resources" => resources).to_json
    assert_equal BUCKET, T::Template.from_json("Resources" => resources).to_json
    assert_equal BUCKET, T::Template.template("Resources" => resources).to_json
  end

  def test_the_options_are_a_second_argument_written_as_keywords_or_as_a_hash
    [ T, T::Template ].each do |owner|
      assert_thrown(/dependency cycle/) { owner.from_json(CYCLE, skip_cyclical_dependencies_check: false) }
      assert_thrown(/dependency cycle/) { owner.from_json(CYCLE, { skip_cyclical_dependencies_check: false }) }
      owner.from_json(CYCLE, skip_cyclical_dependencies_check: true)
      owner.from_json(CYCLE, { skip_cyclical_dependencies_check: true })
      assert_thrown(/dependency cycle/) { owner.from_string(CYCLE.to_json, skip_cyclical_dependencies_check: false) }
      assert_thrown(/dependency cycle/) { owner.from_string(CYCLE.to_json, { skip_cyclical_dependencies_check: false }) }
      assert_thrown(/dependency cycle/) { owner.template(CYCLE, skip_cyclical_dependencies_check: false) }
      assert_thrown(/dependency cycle/) { owner.template(CYCLE, { skip_cyclical_dependencies_check: false }) }
    end
  end

  # --- to_json

  def test_to_json_is_the_template_as_the_cdk_returns_it
    assert_instance_of Hash, T.from_json(BUCKET).to_json
    assert_equal BUCKET, T.from_json(BUCKET).to_json
  end

  def test_the_json_library_can_serialize_a_template
    template = T.from_json(BUCKET)

    assert_equal BUCKET.to_json, JSON.generate(template)
    assert_equal JSON.pretty_generate(BUCKET), JSON.pretty_generate(template)
  end

  # --- return values

  def test_the_methods_that_assert_give_nothing_back
    template = T.from_json({
      "Parameters" => { "P" => { "Type" => "String" } },
      "Mappings" => { "M" => { "A" => { "B" => "C" } } },
      "Conditions" => { "C" => { "Fn::Equals" => [ "A", "A" ] } },
      "Resources" => { "Bucket" => VERSIONED_BUCKET },
      "Outputs" => { "O" => { "Value" => "V" } }
    })
    assertions = [
      -> { template.resource_count_is("AWS::S3::Bucket", 1) },
      -> { template.resource_properties_count_is("AWS::S3::Bucket", { "VersioningConfiguration" => { "Status" => "Enabled" } }, 1) },
      -> { template.has_resource_properties("AWS::S3::Bucket", { "VersioningConfiguration" => { "Status" => "Enabled" } }) },
      -> { template.has_resource("AWS::S3::Bucket", { "Type" => "AWS::S3::Bucket" }) },
      -> { template.all_resources("AWS::S3::Bucket", { "Type" => "AWS::S3::Bucket" }) },
      -> { template.all_resources_properties("AWS::S3::Bucket", { "VersioningConfiguration" => { "Status" => "Enabled" } }) },
      -> { template.has_parameter("P", { "Type" => "String" }) },
      -> { template.has_output("O", { "Value" => "V" }) },
      -> { template.has_mapping("M", { "A" => { "B" => "C" } }) },
      -> { template.has_condition("C", { "Fn::Equals" => [ "A", "A" ] }) },
      -> { template.template_matches({ "Resources" => {} }) }
    ]

    assertions.each_with_index do |assertion, index|
      assert_nil assertion.call, "assertion #{index} returned a value"
    end
  end

  def test_template_matches_names_each_mismatch_on_a_line_of_its_own
    template = T.from_json({ "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" } } })

    error = assert_raises(T::AssertionError) do
      template.template_matches({ "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "DeletionPolicy" => "Retain" } } })
    end

    # The path is the whole one, from the root of the template.
    assert_equal "Template did not match as expected. The following mismatches were found:\n" \
      "\tMissing key 'DeletionPolicy' at /Resources/Bucket/DeletionPolicy (using object_like matcher)", error.message
    template.template_matches(T.object_equals({ "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" } } }))
  end

  def test_a_section_that_is_missing_reads_as_empty
    template = T.from_json({})

    assert_equal({}, template.find_resources("AWS::S3::Bucket"))
    assert_equal({}, template.find_parameters("*"))
    assert_equal({}, template.find_outputs("*"))
    assert_equal({}, template.find_mappings("*"))
    assert_equal({}, template.find_conditions("*"))
    assert_equal({}, template.find_parameters("P", { "Type" => "String" }))
  end

  def test_the_queries_give_the_entries_of_the_template
    policy = { "Type" => "AWS::S3::BucketPolicy" }
    template = T.from_json({ "Resources" => { "Bucket" => VERSIONED_BUCKET, "Policy" => policy } })

    assert_equal({ "Bucket" => VERSIONED_BUCKET }, template.find_resources("AWS::S3::Bucket"))
    assert_equal({ "Bucket" => VERSIONED_BUCKET }, template.find_resources("AWS::S3::Bucket", { "Properties" => { "VersioningConfiguration" => { "Status" => "Enabled" } } }))
    assert_equal({}, template.find_resources("AWS::S3::Bucket", { "Properties" => { "Nope" => 1 } }))
    assert_equal({ "Bucket" => VERSIONED_BUCKET }, template.find_resources("AWS::S3::Bucket", T.not_({ "Properties" => { "Nope" => 1 } })))
    assert_equal "Bucket", template.get_resource_id("AWS::S3::Bucket")
  end

  # --- get(path): this tool's addition

  def test_get_gives_the_value_at_a_path_as_a_capture
    template = T.from_json(TEMPLATE)

    assert_instance_of T::Capture, template.get("Resources.Fn.Properties.Timeout")
    assert_equal 30, template.get("Resources.Fn.Properties.Timeout").as_number
    assert_equal "ruby4.0", template.get("Resources.Fn.Properties.Runtime").as_string
    assert_equal [ "a", "b" ], template.get("Resources.Fn.Properties.Layers").as_array
    assert_equal({ "Timeout" => 30, "Runtime" => "ruby4.0", "Layers" => [ "a", "b" ], "VpcConfig" => nil },
      template.get("Resources.Fn.Properties").as_object)
  end

  def test_get_walks_into_arrays_by_index
    template = T.from_json(TEMPLATE)

    assert_equal "a", template.get("Resources.Fn.Properties.Layers.0").as_string
    assert_equal "b", template.get("Resources.Fn.Properties.Layers.1").as_string
    assert_equal "a", template.get([ "Resources", "Fn", "Properties", "Layers", 0 ]).as_string
  end

  def test_get_takes_a_list_of_keys_for_a_key_that_contains_a_dot
    assert_equal "a key with a dot", T.from_json(TEMPLATE).get([ "a.b" ]).as_string
  end

  def test_get_of_the_empty_path_is_the_whole_template
    assert_equal TEMPLATE, T.from_json(TEMPLATE).get("").as_object
  end

  def test_get_of_a_path_that_leaves_nowhere_raises
    template = T.from_json(TEMPLATE)

    [
      "Resources.Fn.Properties.Nope",
      "Resources.Nope.Properties",
      "Resources.Fn.Properties.Layers.5",
      "Resources.Fn.Properties.Layers.x",
      "Resources.Fn.Type.X",
      "Resources.Fn.Properties.VpcConfig.X"
    ].each do |path|
      error = assert_raises(T::AssertionError, "#{path} gave a value") { template.get(path) }

      assert_equal "Template has no value at #{path}", error.message
    end
  end

  def test_get_of_a_null_gives_a_capture_that_refuses_it
    template = T.from_json(TEMPLATE)

    capture = template.get("Resources.Fn.Properties.VpcConfig")

    assert_instance_of T::Capture, capture
    # A capture only holds what passed its test, and null does not: its as_* say
    # that nothing was captured, and the CDK's message is on the test's result.
    error = assert_raises(T::AssertionError) { capture.as_object }

    assert_equal "No value captured", error.message
    assert_match(/Can only capture non-nullish values\. Found null/, capture.test(nil).to_human_strings.first)
  end

  def test_the_capture_of_get_checks_the_type_as_any_capture
    template = T.from_json(TEMPLATE)

    assert_thrown(/Captured value is expected to be string but found number/) { template.get("Resources.Fn.Properties.Timeout").as_string }
    assert_thrown(/expected to be array but found object/) { template.get("Resources.Fn").as_array }
  end

  def test_each_get_gives_a_capture_of_its_own
    template = T.from_json(TEMPLATE)

    refute_same template.get("Resources.Fn"), template.get("Resources.Fn")
    assert_equal false, template.get("Resources.Fn.Properties.Timeout").next
  end

  # --- the order of the closest matches

  def test_the_closest_matches_are_the_first_three_in_the_order_node_sorts_strings
    of_type = ->(name) { [ name, { "Type" => "AWS::S3::Bucket", "Properties" => { "a" => 1 } } ] }
    resources = [ of_type.call("Zeta"), of_type.call("alpha"), of_type.call("beta"), of_type.call("gamma") ].to_h
    template = T.from_json({ "Resources" => resources })

    error = assert_raises(T::AssertionError) { template.has_resource_properties("AWS::S3::Bucket", { "a" => 2 }) }
    message = error.message

    assert_includes message, "Template has 4 resources with type AWS::S3::Bucket, but none match as expected.\nThe 3 closest matches:\n"
    positions = [ "alpha ::", "beta ::", "gamma ::" ].map do |entry|
      line = message.lines.find { |candidate| candidate.start_with?(entry) }

      assert line, "#{entry} is missing from:\n#{message}"
      message.lines.index(line)
    end
    assert_equal positions, positions.sort, "the closest matches are not in alphabetical order:\n#{message}"
    refute_includes message, "Zeta"
  end

  private

  # The block throws, and the message of what it throws matches the pattern.
  def assert_thrown(pattern)
    error = assert_raises(T::AssertionError, StandardError) { yield }
    assert_match pattern, error.message
    error
  end
end
