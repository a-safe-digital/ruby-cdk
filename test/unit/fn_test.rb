# frozen_string_literal: true

require "test_helper"

# This tool's own tests of Fn. The CDK's own cases for it are in test/cdk/core/fn_test.rb.
class FnTest < Minitest::Test
  Target = Struct.new(:logical_id)
  NamedCondition = Struct.new(:name)

  Fn = RubyCdk::Fn
  Lazy = RubyCdk::Lazy

  def test_ref_takes_a_string_a_symbol_or_a_resource
    assert_equal({ "Ref" => "Table" }, Fn.ref("Table"))
    assert_equal({ "Ref" => "Table" }, Fn.ref(:Table))
    assert_equal({ "Ref" => "Table" }, Fn.ref(Target.new("Table")))
  end

  def test_ref_and_get_att_take_nothing_else
    error = assert_raises(RubyCdk::UsageError) { Fn.ref(Object.new) }

    assert_match(/\AFn\.ref takes a resource, a parameter or a logical ID, got #<Object:/, error.message)
    assert_raises(RubyCdk::UsageError) { Fn.get_att(42, "Arn") }
  end

  def test_get_att
    assert_equal({ "Fn::GetAtt" => [ "FnRole", "Arn" ] }, Fn.get_att(Target.new("FnRole"), "Arn"))
    assert_equal({ "Fn::GetAtt" => [ "FnRole", "Arn" ] }, Fn.get_att("FnRole", :Arn))
  end

  def test_sub_with_and_without_variables
    assert_equal({ "Fn::Sub" => "${Table}" }, Fn.sub("${Table}"))
    assert_equal({ "Fn::Sub" => [ "Hi ${Name}", { "Name" => "x" } ] }, Fn.sub("Hi ${Name}", Name: "x"))
    assert_equal({ "Fn::Sub" => [ "Hi ${Name}", { "Name" => "x" } ] }, Fn.sub("Hi ${Name}", "Name" => "x"))

    error = assert_raises(RubyCdk::UsageError) { Fn.sub("Hi ${Name}", 1 => "x") }

    assert_equal "The keys of Fn.sub variables must be Strings or Symbols, got 1", error.message
  end

  def test_join_takes_the_list_as_one_array_or_as_several_arguments
    assert_equal({ "Fn::Join" => [ "", [ "a", "b" ] ] }, Fn.join("", "a", "b"))
    assert_equal({ "Fn::Join" => [ "-", [ "a", "b" ] ] }, Fn.join("-", [ "a", "b" ]))
    assert_equal({ "Fn::Join" => [ "-", [ "a", "b", "c" ] ] }, Fn.join("-", [ "a" ], "b", "c"))
    assert_equal({ "Fn::Join" => [ ",", %w[ a b ] ] }, Fn.join(",", Fn.split(",", "a,b")))
  end

  def test_join_takes_a_lone_hash_as_the_list_cloudformation_computes_and_an_array_as_a_list_of_one
    assert_equal({ "Fn::Join" => [ ",", { "Fn::GetAZs" => "" } ] }, Fn.join(",", Fn.get_azs))
    assert_equal({ "Fn::Join" => [ ",", [ { "Fn::GetAZs" => "" } ] ] }, Fn.join(",", [ Fn.get_azs ]))
    assert_equal({ "Fn::Join" => [ ",", { "Fn::Split" => [ ",", { "Fn::ImportValue" => "X" } ] } ] },
      Fn.join(",", Fn.split(",", Fn.import_value("X"))))
  end

  def test_join_waits_for_a_lazy_that_answers_the_list
    lazy_join = Fn.join("-", Lazy.new { %w[ a b ] })

    assert_kind_of Lazy, lazy_join
    assert_equal({ "Fn::Join" => [ "-", %w[ a b ] ] }, lazy_join.resolve(nil))
  end

  def test_join_needs_at_least_one_value
    error = assert_raises(RubyCdk::UsageError) { Fn.join(".", []) }

    assert_equal "Fn.join requires at least one value to be provided", error.message
    assert_raises(RubyCdk::UsageError) { Fn.join(".") }
  end

  def test_select_answers_the_element_when_nothing_in_it_is_an_intrinsic_and_an_fn_select_otherwise
    assert_equal "a", Fn.select(0, %w[ a b ])
    assert_equal({ "Plain" => 1 }, Fn.select(0, [ { "Plain" => 1 }, "b" ]))
    assert_nil Fn.select(5, %w[ a b ])

    assert_equal({ "Fn::Select" => [ 1, [ { "Ref" => "A" }, "b" ] ] }, Fn.select(1, [ Fn.ref("A"), "b" ]))
    assert_equal({ "Fn::Select" => [ 0, { "Fn::GetAZs" => "" } ] }, Fn.select(0, Fn.get_azs))
    assert_equal({ "Fn::Select" => [ "1", %w[ a b ] ] }, Fn.select("1", %w[ a b ]))
    assert_equal({ "Fn::Select" => [ 1, [ [ Fn.ref("A") ], "b" ] ] }, Fn.select(1, [ [ Fn.ref("A") ], "b" ]))

    error = assert_raises(RubyCdk::UsageError) { Fn.select(0, "not a list") }

    assert_equal "Fn.select takes an Array or a function that returns a list, got \"not a list\"", error.message
  end

  def test_select_waits_for_a_lazy_and_answers_the_element_of_what_it_resolves_to
    lazy_select = Fn.select(1, [ Lazy.new { 0 }, "b" ])

    assert_kind_of Lazy, lazy_select
    assert_equal "b", lazy_select.resolve(nil)
    assert_equal "a", Fn.select(0, Lazy.new { %w[ a b ] }).resolve(nil)
  end

  def test_split_answers_the_list_when_the_string_is_known_and_an_fn_split_otherwise
    assert_equal %w[ hello world yeah ], Fn.split(":", "hello:world:yeah")
    assert_equal [ "a", "", "b" ], Fn.split(",", "a,,b")
    assert_equal [ "a", "" ], Fn.split(",", "a,")
    assert_equal [ "" ], Fn.split(",", "")
    assert_equal %w[ a b ], Fn.split("", "ab")
    assert_equal [ "a", "", "", "b" ], Fn.split(" ", "a   b")

    assert_equal({ "Fn::Split" => [ ",", Fn.import_value("Shared") ] }, Fn.split(",", Fn.import_value("Shared")))
    lazy_split = Fn.split(",", Lazy.new { "a,b" })
    assert_kind_of Lazy, lazy_split
    assert_equal %w[ a b ], lazy_split.resolve(nil)
    assert_equal %w[ a b ], Fn.split(",", "a,b", 3)

    error = assert_raises(RubyCdk::UsageError) { Fn.split(nil, "a,b") }

    assert_equal "Fn.split takes a String separator, got nil", error.message
    error = assert_raises(RubyCdk::UsageError) { Fn.split(",", Fn.import_value("X"), -1) }
    assert_equal "Fn.split: assumed_length must be an Integer of at least 0, got -1", error.message
  end

  def test_a_split_of_an_unknown_length_with_an_assumed_length_is_a_list_of_known_length
    split = { "Fn::Split" => [ ",", { "Fn::ImportValue" => "X" } ] }

    assert_equal [ { "Fn::Select" => [ 0, split ] }, { "Fn::Select" => [ 1, split ] } ], Fn.split(",", Fn.import_value("X"), 2)
    assert_equal [], Fn.split(",", Fn.import_value("X"), 0)
  end

  def test_import_list_value_is_a_split_on_commas_of_an_import
    split = { "Fn::Split" => [ ",", { "Fn::ImportValue" => "ExportName" } ] }

    assert_equal [ { "Fn::Select" => [ 0, split ] }, { "Fn::Select" => [ 1, split ] } ], Fn.import_list_value("ExportName", 2)
    other = Fn.import_list_value(:ExportName, 1, "|")
    assert_equal({ "Fn::Split" => [ "|", { "Fn::ImportValue" => "ExportName" } ] }, other.first["Fn::Select"][1])
  end

  def test_minimal_join_splices_a_join_with_the_same_delimiter_and_glues_neighbouring_literals
    assert_equal [ "a-b" ], Fn.minimal_join("-", [ "a", "b" ])
    assert_equal [ { "Ref" => "A" }, "b-c" ], Fn.minimal_join("-", [ { "Ref" => "A" }, "b", "c" ])
    assert_equal [ "a-b", { "Ref" => "A" }, "c-d" ], Fn.minimal_join("-", [ "a", "b", { "Ref" => "A" }, "c", "d" ])
    assert_equal [ "abc" ], Fn.minimal_join("", [ "a", "b", "c" ])
    assert_equal [ { "Plain" => 1 } ], Fn.minimal_join("", [ { "Plain" => 1 } ])
    assert_equal [], Fn.minimal_join("", [])

    same = { "Fn::Join" => [ "-", [ "b", { "Ref" => "A" }, "c" ] ] }
    other = { "Fn::Join" => [ ":", [ "x", "y" ] ] }
    assert_equal [ "a-b", { "Ref" => "A" }, "c-d" ], Fn.minimal_join("-", [ "a", same, "d" ])
    assert_equal [ "a", other, "d" ], Fn.minimal_join("-", [ "a", other, "d" ])
    assert_equal [ "a", { "Fn::Join" => [ "-", { "Ref" => "A" } ] }, "d" ], Fn.minimal_join("-", [ "a", { "Fn::Join" => [ "-", { "Ref" => "A" } ] }, "d" ])

    values = [ "a", "b" ]
    Fn.minimal_join("-", values)
    assert_equal [ "a", "b" ], values
  end

  def test_minimal_join_writes_a_number_the_way_javascript_does
    assert_equal [ "1-2" ], Fn.minimal_join("-", [ 1, 2 ])
    assert_equal "3-4.5", Fn.minimal_join("-", [ 3, 4.5 ]).first
    assert_equal "1-2.5", Fn.minimal_join("-", [ 1.0, 2.5 ]).first
    assert_equal [ 1.0 ], Fn.minimal_join("-", [ 1.0 ])
  end

  def test_base64_import_value_and_get_azs
    assert_equal({ "Fn::Base64" => "text" }, Fn.base64("text"))
    assert_equal({ "Fn::ImportValue" => "Net-Bucket" }, Fn.import_value("Net-Bucket"))
    assert_equal({ "Fn::ImportValue" => "Net" }, Fn.import_value(:Net))

    assert_equal({ "Fn::GetAZs" => "" }, Fn.get_azs)
    assert_equal({ "Fn::GetAZs" => "" }, Fn.get_azs(nil))
    assert_equal({ "Fn::GetAZs" => "eu-west-1" }, Fn.get_azs("eu-west-1"))
    assert_equal({ "Fn::GetAZs" => { "Ref" => "AWS::Region" } }, Fn.get_azs(Fn.ref("AWS::Region")))
  end

  def test_find_in_map_takes_a_default_value_for_a_key_that_is_missing
    assert_equal({ "Fn::FindInMap" => [ "Regions", "eu", "west" ] }, Fn.find_in_map(:Regions, "eu", "west"))
    assert_equal({ "Fn::FindInMap" => [ "Regions", "eu", "west" ] }, Fn.find_in_map("Regions", "eu", "west"))
    assert_equal({ "Fn::FindInMap" => [ "Regions", "eu", "west", { "DefaultValue" => "t3.micro" } ] },
      Fn.find_in_map("Regions", "eu", "west", default_value: "t3.micro"))
    assert_equal({ "Fn::FindInMap" => [ "Regions", "eu", "west", { "DefaultValue" => "" } ] },
      Fn.find_in_map("Regions", "eu", "west", default_value: ""))
  end

  def test_parse_domain_name_answers_the_domain_of_a_literal_url
    assert_equal "test.com", Fn.parse_domain_name("https://test.com/")
    assert_equal "test.com", Fn.parse_domain_name("https://test.com")
    # What comes before the first / after the authority, as the CDK's does: a
    # port is part of what this function answers.
    assert_equal "test.com:8080", Fn.parse_domain_name("http://test.com:8080/a/b?q=1")
    assert_equal "", Fn.parse_domain_name("https://")
  end

  def test_parse_domain_name_waits_for_a_lazy_url
    lazy_domain = Fn.parse_domain_name(Lazy.new { "https://test.com/x" })

    assert_kind_of Lazy, lazy_domain
    assert_equal "test.com", lazy_domain.resolve(nil)
  end

  def test_cidr_writes_the_fn_cidr_and_checks_the_count_when_it_is_a_number
    assert_equal({ "Fn::Cidr" => [ "10.0.0.0/16", 6, "5" ] }, Fn.cidr("10.0.0.0/16", 6, "5"))
    assert_equal({ "Fn::Cidr" => [ "10.0.0.0/16", 6, 5 ] }, Fn.cidr("10.0.0.0/16", 6, 5))
    assert_equal({ "Fn::Cidr" => [ "10.0.0.0/16", "6" ] }, Fn.cidr("10.0.0.0/16", "6"))
    assert_equal({ "Fn::Cidr" => [ Fn.get_att("Vpc", "CidrBlock"), Fn.ref("Count"), 8 ] },
      Fn.cidr(Fn.get_att("Vpc", "CidrBlock"), Fn.ref("Count"), 8))

    error = assert_raises(RubyCdk::UsageError) { Fn.cidr("10.0.0.0/16", 300, 8) }

    assert_equal "Fn::Cidr's count attribute must be between 1 and 256, 300 was provided.", error.message
    assert_raises(RubyCdk::UsageError) { Fn.cidr("10.0.0.0/16", 0, 8) }
    assert_raises(RubyCdk::UsageError) { Fn.cidr("10.0.0.0/16", 257, 8) }
  end

  def test_get_stack_output_names_the_stack_the_output_and_where_to_ask
    assert_equal({ "Fn::GetStackOutput" => { "StackName" => "producer", "OutputName" => "VpcId" } }, Fn.get_stack_output("producer", "VpcId"))
    assert_equal({ "Fn::GetStackOutput" => { "StackName" => "producer", "OutputName" => :vpc_id, "Region" => "us-west-2" } },
      Fn.get_stack_output("producer", :vpc_id, "us-west-2"))
    assert_equal({ "Fn::GetStackOutput" => { "StackName" => "producer", "OutputName" => "VpcId", "RoleArn" => "arn:aws:iam::1:role/r" } },
      Fn.get_stack_output("producer", "VpcId", nil, "arn:aws:iam::1:role/r"))
    assert_equal({ "Fn::GetStackOutput" => { "StackName" => "producer", "OutputName" => "VpcId", "Region" => "us-west-2", "RoleArn" => "arn" } },
      Fn.get_stack_output("producer", "VpcId", "us-west-2", "arn"))
  end

  def test_transform_writes_the_fn_transform
    assert_equal({ "Fn::Transform" => { "Name" => "AWS::Include", "Parameters" => { "Location" => "s3://bucket/key" } } },
      Fn.transform("AWS::Include", "Location" => "s3://bucket/key"))

    error = assert_raises(RubyCdk::UsageError) { Fn.transform("AWS::Include", "s3://bucket/key") }

    assert_equal "Fn.transform takes a Hash of parameters, got \"s3://bucket/key\"", error.message
  end

  def test_to_json_string_answers_a_string_for_plain_data_and_the_intrinsic_when_an_intrinsic_is_inside
    assert_equal '{"key":"value"}', Fn.to_json_string("key" => "value")
    assert_equal '{"a":[1,true]}', Fn.to_json_string("a" => [ 1, true ])
    assert_equal({ "Fn::ToJsonString" => { "key" => { "Ref" => "Name" } } }, Fn.to_json_string("key" => Fn.ref("Name")))
    assert_equal({ "Fn::ToJsonString" => [ { "Ref" => "A" } ] }, Fn.to_json_string([ Fn.ref("A") ]))
  end

  def test_to_json_string_waits_for_a_lazy_object
    lazy_json = Fn.to_json_string("key" => Lazy.new { "later" })

    assert_kind_of Lazy, lazy_json
    assert_equal '{"key":"later"}', lazy_json.resolve(nil)
  end

  def test_len_answers_the_number_of_elements_of_an_array_and_the_fn_length_of_a_list_cloudformation_computes
    assert_equal 3, Fn.len(Fn.split("|", "a|b|c"))
    assert_equal 0, Fn.len([])
    assert_equal({ "Fn::Length" => { "Fn::Split" => [ "|", { "Fn::ImportValue" => "X" } ] } }, Fn.len(Fn.split("|", Fn.import_value("X"))))

    error = assert_raises(RubyCdk::UsageError) { Fn.len("nope") }

    assert_equal "Fn.len needs an array, got \"nope\"", error.message
  end

  def test_ref_all_value_of_and_value_of_all_are_the_parameter_type_functions
    assert_equal({ "Fn::RefAll" => "AWS::EC2::VPC::Id" }, Fn.ref_all("AWS::EC2::VPC::Id"))
    assert_equal({ "Fn::ValueOf" => [ "Region", "Primary" ] }, Fn.value_of("Region", "Primary"))
    assert_equal({ "Fn::ValueOfAll" => [ "AWS::EC2::Subnet::Id", "VpcId" ] }, Fn.value_of_all("AWS::EC2::Subnet::Id", "VpcId"))
  end

  def test_contains_each_member_equals_and_each_member_in_are_the_list_conditions
    list = Fn.split(",", Fn.ref("Zones"))

    assert_equal({ "Fn::Contains" => [ list, "eu" ] }, Fn.contains(list, "eu"))
    assert_equal({ "Fn::EachMemberEquals" => [ %w[ dev prod ], "dev" ] }, Fn.each_member_equals(%w[ dev prod ], "dev"))
    assert_equal({ "Fn::EachMemberIn" => [ Fn.value_of_all("AWS::EC2::Subnet::Id", "VpcId"), Fn.ref_all("AWS::EC2::VPC::Id") ] },
      Fn.each_member_in(Fn.value_of_all("AWS::EC2::Subnet::Id", "VpcId"), Fn.ref_all("AWS::EC2::VPC::Id")))
  end

  def test_conditions
    condition = { "Fn::Equals" => [ "a", "a" ] }
    assert_equal({ "Fn::If" => [ "IsA", "yes", "no" ] }, Fn.if("IsA", "yes", "no"))
    assert_equal({ "Fn::If" => [ "IsA", "yes", "no" ] }, Fn.if(NamedCondition.new("IsA"), "yes", "no"))
    assert_equal condition, Fn.equals("a", "a")
    assert_equal({ "Fn::And" => [ condition ] }, Fn.and_(condition))
    assert_equal({ "Fn::Or" => [ condition ] }, Fn.or_(condition))
    assert_equal({ "Fn::Not" => [ condition ] }, Fn.not_(condition))

    error = assert_raises(RubyCdk::UsageError) { Fn.if(Object.new, "yes", "no") }

    assert_match(/\AFn\.if takes a condition the stack declared, or its name, got /, error.message)
  end

  def test_no_value_is_frozen
    assert_predicate Fn::NO_VALUE, :frozen?
  end
end
