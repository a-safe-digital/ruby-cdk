# frozen_string_literal: true

require "test_helper"
require "date"
require "support/core_helpers"

# The resolve phase and the value model of architecture §4: what a Ruby value
# becomes in the template, and what is refused.
class SynthResolverTest < CoreHelpers::TestCase
  # Answers what a zipped asset answers. The class itself belongs to a component that loads later.
  ZippedAsset = Struct.new(:hash, :key) do
    def bucket
      "assets"
    end

    def s3_location
      { "S3Bucket" => bucket, "S3Key" => key }
    end
  end

  def test_a_string_an_integer_a_float_and_a_boolean_are_written_as_they_are
    properties = properties_of(Name: "s", Count: 1, Ratio: 1.5, On: true, Off: false)

    assert_equal({ "Name" => "s", "Count" => 1, "Ratio" => 1.5, "On" => true, "Off" => false }, properties)
  end

  def test_a_symbol_becomes_its_name
    properties = properties_of(Mode: :Active, List: [ :a, :b ])

    assert_equal({ "Mode" => "Active", "List" => [ "a", "b" ] }, properties)
    assert_predicate properties["Mode"], :frozen?
  end

  def test_a_nil_leaves_its_key_out
    template = build_stack {
      resource("A", "AWS::SNS::Topic", TopicName: "a", DisplayName: nil)
      resource("B", "AWS::SNS::Topic", DisplayName: nil)
      resource("C", "AWS::SNS::Topic", DisplayName: Lazy.new { nil }, Fifo: false)
    }.to_template

    assert_equal({ "Type" => "AWS::SNS::Topic", "Properties" => { "TopicName" => "a" } }, template["Resources"]["A"])
    assert_equal({ "Type" => "AWS::SNS::Topic" }, template["Resources"]["B"])
    assert_equal({ "Type" => "AWS::SNS::Topic", "Properties" => { "Fifo" => false } }, template["Resources"]["C"])
  end

  def test_the_result_of_fn_is_already_what_the_template_holds
    stack = build_stack do
      @topic = resource("Topic", "AWS::SNS::Topic")
      parameter("Stage", type: "String")
      @stage = parameters["Stage"]
      resource("Queue", "AWS::SQS::Queue", "TopicName" => Fn.ref(@topic), "Arn" => Fn.get_att(@topic, "Arn"), "Stage" => Fn.ref(@stage),
        "Name" => Fn.join("-", [ Fn.ref(@stage), "q" ]), "NoValue" => Fn::NO_VALUE)
    end
    topic = stack.instance_variable_get(:@topic)

    assert_equal "Topic", topic.logical_id
    assert_equal(
      { "TopicName" => { "Ref" => "Topic" }, "Arn" => { "Fn::GetAtt" => [ "Topic", "Arn" ] }, "Stage" => { "Ref" => "Stage" },
        "Name" => { "Fn::Join" => [ "-", [ { "Ref" => "Stage" }, "q" ] ] }, "NoValue" => { "Ref" => "AWS::NoValue" } },
      stack.to_template["Resources"]["Queue"]["Properties"]
    )
  end

  def test_a_lazy_is_evaluated_once_wherever_it_appears
    calls = 0
    lazy = Lazy.new { calls += 1; "later" }
    stack = build_stack do
      resource("A", "AWS::SNS::Topic", TopicName: lazy)
      resource("B", "AWS::SQS::Queue", QueueName: lazy, Tags: [ { "Key" => "k", "Value" => lazy } ])
    end

    assert_equal 0, calls
    refute_predicate lazy, :resolved?
    template = stack.to_template

    assert_equal "later", template["Resources"]["A"]["Properties"]["TopicName"]
    assert_equal "later", template["Resources"]["B"]["Properties"]["QueueName"]
    assert_equal "later", template["Resources"]["B"]["Properties"]["Tags"][0]["Value"]
    assert_equal 1, calls
    assert_predicate lazy, :resolved?

    stack.to_template
    assert_equal 1, calls
  end

  def test_a_lazy_may_be_followed_through_ten_lazy_values_and_no_more
    eleven = Lazy.new { "bottom" }
    11.times { inner = eleven; eleven = Lazy.new { inner } }
    stack = build_stack { resource("A", "AWS::SNS::Topic", TopicName: eleven) }

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal 1, error.issues.length
    assert_equal "V0", error.issues.first.rule
    assert_equal "Resources.A.Properties.TopicName", error.issues.first.path
    assert_match(/A chain of Lazy values deeper than 10 levels \(at most 10 Lazy values are followed\)/, error.message)
  end

  def test_a_lazy_that_leads_back_to_itself_is_reported_at_its_place_in_the_template
    cyclic = nil
    cyclic = Lazy.new { cyclic }
    stack = build_stack { resource("A", "AWS::SNS::Topic", "Tags" => [ { "Value" => cyclic } ]) }

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal "Resources.A.Properties.Tags[0].Value", error.issues.first.path
    assert_match(/leads back to itself/, error.message)
  end

  def test_an_error_from_inside_a_lazy_is_not_turned_into_an_issue
    stack = build_stack { resource("A", "AWS::SNS::Topic", TopicName: Lazy.new { raise "the user's bug" }) }

    error = assert_raises(RuntimeError) { stack.to_template }

    assert_equal "the user's bug", error.message
  end

  def test_nothing_the_user_wrote_is_changed
    nested = { "Key" => [ "a", :b ] }
    properties = { "First" => nested, "Second" => nil, "Third" => "x" }
    before = Marshal.load(Marshal.dump(properties))
    stack = build_stack do
      resource("A", "AWS::SNS::Topic", properties)
      resource("B", "AWS::SNS::Topic", "List" => [ 1, 2 ])
    end

    template = stack.to_template

    assert_equal before, properties
    assert_equal [ 1, 2 ], stack.resources.last.properties["List"]
    assert_not_same nested, template["Resources"]["A"]["Properties"]["First"]
    assert_not_same stack.resources.first.properties, template["Resources"]["A"]["Properties"]

    nested.freeze
    properties.freeze
    stack.resources.last.properties["List"].freeze
    assert_equal template, stack.to_template
  end

  def test_arrays_and_hashes_are_written_recursively_in_the_order_they_were_written
    properties = properties_of("Zed" => 1, Alpha: { "Inner" => [ { "Deep" => :value } ], :sym => "s" }, Last: [ [], {} ])

    assert_equal({ "Zed" => 1, "Alpha" => { "Inner" => [ { "Deep" => "value" } ], "sym" => "s" }, "Last" => [ [], {} ] }, properties)
    assert_equal [ "Zed", "Alpha", "Last" ], properties.keys
    assert_equal [ "Inner", "sym" ], properties["Alpha"].keys
  end

  def test_a_resource_where_a_value_is_expected_is_an_error_that_names_fn_ref
    stack = build_stack do
      @topic = resource("Topic", "AWS::SNS::Topic")
      resource("Queue", "AWS::SQS::Queue", "QueueName" => @topic)
    end

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal 1, error.issues.length
    assert_equal "Resources.Queue.Properties.QueueName", error.issues.first.path
    assert_includes error.message, "the resource App/blog/Topic is not a value: did you mean `Fn.ref(...)`?"
    assert_equal "Fn.ref(resource) writes its Ref, and Fn.get_att(resource, \"Arn\") an attribute", error.issues.first.hint
  end

  def test_a_zipped_asset_where_a_value_is_expected_is_an_error_that_names_its_three_methods
    stack = build_stack { resource("Fn", "AWS::Lambda::Function", "Code" => ZippedAsset.new("abc", "abc.zip")) }

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal "Resources.Fn.Properties.Code", error.issues.first.path
    assert_includes error.message, "a zipped asset is not a value: use `.s3_location`, `.bucket` or `.key`"
  end

  def test_a_time_is_an_error_that_asks_for_an_iso_8601_string
    [ Time.at(0).utc, DateTime.new(2026, 11, 23), Date.new(2026, 11, 23) ].each do |time|
      stack = build_stack { resource("A", "AWS::SNS::Topic", DisplayName: time) }

      error = assert_raises(RubyCdk::ValidationError, time.class.name) { stack.to_template }

      assert_equal "V0", error.issues.first.rule
      assert_equal "Resources.A.Properties.DisplayName", error.issues.first.path
      assert_match(/is not a value: write an ISO 8601 string/, error.message)
      assert_match(/time\.utc\.iso8601/, error.issues.first.hint)
    end
  end

  def test_a_proc_is_never_called
    called = false
    stack = build_stack { resource("A", "AWS::SNS::Topic", DisplayName: proc { called = true }) }

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    refute called
    assert_match(/a Proc is not a value: a Proc is never called for you/, error.message)
    assert_match(/RubyCdk::Lazy\.new \{ \.\.\. \}/, error.issues.first.hint)
  end

  def test_anything_else_is_an_error_that_names_the_class
    stack = build_stack do
      parameter("N", type: "Number")
      resource("A", "AWS::SNS::Topic", DisplayName: Object.new, "Owner" => stack, "Count" => 2r, "Stage" => parameters["N"])
    end

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal [
      "Resources.A.Properties.DisplayName", "Resources.A.Properties.Owner", "Resources.A.Properties.Count", "Resources.A.Properties.Stage"
    ], error.issues.map(&:path)
    assert_match(/Resources\.A\.Properties\.DisplayName: an Object is not a value/, error.message)
    assert_match(/App\/blog is a construct, and a construct is not a value/, error.message)
    assert_match(/Resources\.A\.Properties\.Count: a Rational is not a value/, error.message)
    assert_match(/the parameter N of the stack is not a value/, error.message)
  end

  def test_nil_inside_an_array_and_a_key_that_is_not_a_string_are_errors
    stack = build_stack do
      @topic = resource("Topic", "AWS::SNS::Topic")
      resource("A", "AWS::SNS::Topic", "List" => [ "a", nil ], "Map" => { 1 => "one" }, "Other" => { @topic => "x" })
    end

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal [ "Resources.A.Properties.List[1]", "Resources.A.Properties.Map.1", "Resources.A.Properties.Other" ], error.issues.map(&:path)
    assert_match(/Resources\.A\.Properties\.List\[1\]: nil is not a value inside an array/, error.message)
    assert_match(/Resources\.A\.Properties\.Map\.1: a Hash key must be a String or a Symbol, got 1/, error.message)
    assert_match(/a Hash key must be a String or a Symbol, got #<RubyCdk::Cfn::Resource/, error.message)
  end

  def test_infinity_and_nan_are_not_values
    stack = build_stack { resource("A", "AWS::SNS::Topic", Ratio: 1.0 / 0, Other: -1.0 / 0, More: Float::NAN) }

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal 3, error.issues.length
    assert_match(/Resources\.A\.Properties\.Ratio: Infinity and NaN are not values/, error.message)
  end

  def test_every_problem_is_reported_at_once_under_one_rule
    stack = build_stack do
      @topic = resource("Topic", "AWS::SNS::Topic")
      resource("A", "AWS::SNS::Topic", DisplayName: Time.now, "Owner" => @topic)
      resource("B", "AWS::SQS::Queue", "Code" => ZippedAsset.new("abc", "abc.zip"), "Tags" => [ nil ])
      resource("C", "AWS::SQS::Queue", "When" => proc {}, "Who" => Object.new)
    end

    error = assert_raises(RubyCdk::ValidationError) { stack.to_template }

    assert_equal %w[ V0 ] * 6, error.issues.map(&:rule)
    assert_equal [
      "Resources.A.Properties.DisplayName", "Resources.A.Properties.Owner", "Resources.B.Properties.Code",
      "Resources.B.Properties.Tags[0]", "Resources.C.Properties.When", "Resources.C.Properties.Who"
    ], error.issues.map(&:path)
    assert_equal 6, error.message.lines.length
    assert_match(/\AV0 Resources\.A\.Properties\.DisplayName: /, error.message)
  end

  def test_the_template_holds_only_plain_values_afterwards
    stack = build_stack do
      @topic = resource("Topic", "AWS::SNS::Topic")
      resource("A", "AWS::SQS::Queue", "Name" => Fn.join("", [ "a", Lazy.new { Fn.ref(@topic) }, "b" ]), "Key" => :symbol)
    end

    template = stack.to_template

    assert_equal({ "Type" => "AWS::SQS::Queue", "Properties" => { "Name" => { "Fn::Join" => [ "", [ "a", { "Ref" => "Topic" }, "b" ] ] }, "Key" => "symbol" } },
      template["Resources"]["A"])
    assert_equal template, JSON.parse(RubyCdk::Synth::Serializer.call(template))
  end

  def test_resolve_answers_one_value_the_way_the_template_holds_it
    stack = build_stack
    lazy = Lazy.new { :later }

    assert_equal "later", stack.resolve(lazy)
    assert_equal nil, stack.resolve(nil)
    assert_equal({ "Ref" => "Topic" }, stack.resolve(Fn.ref("Topic")))
    assert_equal "ab", stack.resolve(Fn.join("", [ "a", "b" ]))
    assert_equal "abc", stack.resolve(Fn.join("", [ "a", Fn.join("", [ "b", "c" ]) ]))
    assert_equal [ 1, "two" ], stack.resolve([ 1, :two ])

    error = assert_raises(RubyCdk::ValidationError) { stack.resolve(Object.new) }
    assert_match(/an Object is not a value/, error.message)
  end

  def test_a_join_whose_parts_are_all_known_becomes_the_shortest_way_of_saying_it
    stack = build_stack { @topic = resource("Topic", "AWS::SNS::Topic") }
    topic = stack.instance_variable_get(:@topic)
    join = ->(parts) { stack.resolve(Fn.join("-", parts)) }

    assert_equal "a-b-c", join.call([ "a", "b", "c" ])
    assert_equal "a", join.call([ "a" ])
    assert_equal({ "Ref" => "Topic" }, join.call([ Fn.ref(topic) ]))
    assert_equal({ "Fn::Join" => [ "-", [ "a-b", { "Ref" => "Topic" }, "c-d" ] ] }, join.call([ "a", "b", Fn.ref(topic), "c", "d" ]))
    assert_equal({ "Fn::Join" => [ "-", [ { "Ref" => "Topic" }, { "Ref" => "Topic" } ] ] }, join.call([ Fn.ref(topic), Fn.ref(topic) ]))
    assert_equal "a:b", join.call([ Fn.join(":", [ "a", "b" ]) ])
    assert_equal "ab-c", join.call([ Fn.join("-", [ "a", "b" ]), "c" ])
  end

  private

  def properties_of(**properties)
    build_stack { resource("Thing", "AWS::SNS::Topic", properties) }.to_template.fetch("Resources").fetch("Thing").fetch("Properties")
  end
end
