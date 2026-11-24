# frozen_string_literal: true

require "test_helper"
require "support/nag_case"

# The value helper: what a rule may read as a literal, what it must leave
# alone, and how a path is read.
class NagValuesTest < Minitest::Test
  Values = RubyCdk::Nag::Values
  Reader = RubyCdk::Nag::Reader
  Undecided = RubyCdk::Nag::Undecided

  # --- literal or dynamic

  def test_every_intrinsic_function_is_dynamic
    [
      { "Ref" => "Port" },
      { "Ref" => "AWS::Region" },
      { "Fn::If" => [ "IsProd", 80, 8080 ] },
      { "Fn::Sub" => "${Bucket}.amazonaws.com" },
      { "Fn::Sub" => [ "Hi ${Name}", { "Name" => "x" } ] },
      { "Fn::GetAtt" => [ "Role", "Arn" ] },
      { "Fn::Join" => [ "", [ "a", "b" ] ] },
      { "Fn::Select" => [ "0", [ "a" ] ] },
      { "Fn::FindInMap" => [ "M", "a", "b" ] },
      { "Fn::Base64" => "x" },
      { "Fn::Length" => [ "a" ] }
    ].each do |value|
      assert Values.intrinsic?(value), "#{value.inspect} should be an intrinsic function"
      assert Values.dynamic?(value), "#{value.inspect} should be dynamic"
    end
  end

  def test_a_fn_sub_without_a_variable_is_the_string_it_holds
    [ { "Fn::Sub" => "ruby4.0" }, { "Fn::Sub" => [ "plain", { "NeverUsed" => { "Ref" => "X" } } ] }, { "Fn::Sub" => "costs ${!Literal} dollars" } ].each do |value|
      refute Values.intrinsic?(value), "#{value.inspect} holds no variable"
      refute Values.dynamic?(value), "#{value.inspect} holds no variable"
    end
    assert_equal "ruby4.0", Reader.new({ "Runtime" => { "Fn::Sub" => "ruby4.0" } }).string("Runtime")
    assert_equal "plain", Reader.new({ "Runtime" => { "Fn::Sub" => [ "plain", { "NeverUsed" => { "Ref" => "X" } } ] } }).raw("Runtime")
  end

  def test_a_literal_is_not_dynamic
    [
      "*", "s3:*", "${LooksLikeAVariableOutsideAnFnSub}", 22, 0.5, true, false, nil, [], {},
      [ "a", 1, nil ], { "Action" => "*" }, { "Statement" => [ { "Effect" => "Allow", "Resource" => "*" } ] },
      { "Fn" => "a key that does not start with Fn::" }, { "Fn" => ":Sub" }, { "Condition" => "IsProd" }
    ].each do |value|
      refute Values.dynamic?(value), "#{value.inspect} is a literal"
    end
  end

  def test_an_intrinsic_anywhere_inside_makes_the_whole_value_dynamic
    [
      [ "a", { "Ref" => "P" } ],
      { "Statement" => [ { "Action" => "*" }, { "Action" => { "Fn::If" => [ "C", "a", "b" ] } } ] },
      { "Properties" => { "PublicAccessBlockConfiguration" => { "BlockPublicAcls" => { "Ref" => "X" } } } }
    ].each do |value|
      assert Values.dynamic?(value), "#{value.inspect} holds an intrinsic function"
      refute Values.intrinsic?(value), "#{value.inspect} is not itself an intrinsic function"
    end
  end

  def test_aws_no_value_removes_the_property_it_is_written_in
    reader = Reader.new({ "Properties" => { "Encrypted" => { "Ref" => "AWS::NoValue" }, "Encrypted2" => { "Fn::If" => [ "C", true, { "Ref" => "AWS::NoValue" } ] } } })

    assert(Values.no_value?({ "Ref" => "AWS::NoValue" }), "AWS::NoValue should be recognised")
    refute(Values.no_value?({ "Ref" => "Encrypted" }), "a Ref to a parameter is not AWS::NoValue")
    assert_nil reader.raw("Properties.Encrypted")
    refute reader.present?("Properties.Encrypted"), "AWS::NoValue leaves no value present"
    assert_equal({ "Ref" => "AWS::NoValue" }, reader.peek("Properties.Encrypted"))
    assert_nil reader.boolean("Properties.Encrypted")
    # Inside an Fn::If it cannot be seen: the whole value is dynamic.
    assert_raises(Undecided) { reader.raw("Properties.Encrypted2") }
  end

  def test_a_string_that_resolves_to_a_secret_is_not_a_literal_in_the_clear
    [ "{{resolve:secretsmanager:prod/db:SecretString:password}}", "{{resolve:ssm-secure:/prod/db/password}}" ].each do |text|
      assert Values.secret_dynamic_reference?(text), text
    end
    [ "hunter2", "{{resolve:ssm:/prod/db/host}}", "{{resolve:secretsmanager:x}} and more", "prefix {{resolve:ssm-secure:x}}" ].each do |text|
      refute Values.secret_dynamic_reference?(text), text
    end
  end

  # --- raw

  def test_raw_reads_the_value_and_nil_for_what_is_absent
    reader = Reader.new({ "Properties" => { "Encrypted" => true, "Policies" => [ { "PolicyName" => "p" } ] } })

    assert_equal true, reader.raw("Properties.Encrypted")
    assert_equal({ "PolicyName" => "p" }, reader.raw("Properties.Policies[0]"))
    assert_equal "p", reader.raw("Properties.Policies[0].PolicyName")
    assert_nil reader.raw("Properties.StorageEncrypted")
    assert_nil reader.raw("Nothing.Here")
    assert_nil reader.raw("Properties.Policies[3].PolicyName")
    assert_nil reader.raw("Properties.Encrypted.Nested")
  end

  def test_raw_refuses_a_dynamic_value_and_names_where_it_is
    error = assert_raises(Undecided) { Reader.new({ "Properties" => { "Encrypted" => { "Ref" => "E" } } }).raw("Properties.Encrypted") }

    assert_equal "Properties.Encrypted", error.path
    assert_includes error.reason, "dynamic"
  end

  def test_raw_refuses_a_dynamic_value_on_the_way_to_the_value
    template = { "Properties" => { "Policies" => { "Ref" => "P" }, "Rules" => [ { "Ref" => "R" } ] } }
    reader = Reader.new(template)

    error = assert_raises(Undecided) { reader.raw("Properties.Policies[0].PolicyName") }
    assert_equal "Properties.Policies", error.path

    error = assert_raises(Undecided) { reader.raw("Properties.Rules[0].CidrIp") }
    assert_equal "Properties.Rules[0]", error.path
  end

  def test_a_reader_of_nothing_reads_nothing
    reader = Reader.new(nil)

    assert_nil reader.raw("Properties.Encrypted")
    assert_equal [], reader.item_paths("Properties.Policies")
    assert_nil reader.string("A")
  end

  def test_peek_never_raises
    reader = Reader.new({ "A" => { "Ref" => "P" }, "B" => [ { "Fn::If" => [ "C", 1, 2 ] } ] })

    assert_equal({ "Ref" => "P" }, reader.peek("A"))
    assert_equal({ "Fn::If" => [ "C", 1, 2 ] }, reader.peek("B[0]"))
    assert_nil reader.peek("Missing")
    assert_nil reader.peek("A.Nested")
  end

  # --- the typed readers

  def test_string_reads_a_string_and_refuses_anything_else
    reader = Reader.new({ "A" => "x", "B" => 22, "C" => [ "x" ] })

    assert_equal "x", reader.string("A")
    assert_nil reader.string("Missing")
    assert_raises(Undecided) { reader.string("B") }
    assert_raises(Undecided) { reader.string("C") }
  end

  def test_integer_reads_a_number_or_a_numeric_string
    reader = Reader.new({ "A" => 22, "B" => "22", "C" => " 8080 ", "D" => "-1", "E" => "eighty", "F" => 1.5 })

    assert_equal 22, reader.integer("A")
    assert_equal 22, reader.integer("B")
    assert_equal 8080, reader.integer("C")
    assert_equal -1, reader.integer("D")
    assert_nil reader.integer("Missing")
    assert_raises(Undecided) { reader.integer("E") }
    assert_raises(Undecided) { reader.integer("F") }
  end

  def test_boolean_reads_booleans_and_their_names
    reader = Reader.new({ "A" => true, "B" => false, "C" => "true", "D" => "FALSE", "E" => "yes", "F" => 1 })

    assert_equal true, reader.boolean("A")
    assert_equal false, reader.boolean("B")
    assert_equal true, reader.boolean("C")
    assert_equal false, reader.boolean("D")
    assert_nil reader.boolean("Missing")
    assert_raises(Undecided) { reader.boolean("E") }
    assert_raises(Undecided) { reader.boolean("F") }
  end

  def test_object_reads_a_hash
    reader = Reader.new({ "A" => { "x" => 1 }, "B" => [ 1 ], "C" => "x" })

    assert_equal({ "x" => 1 }, reader.object("A"))
    assert_nil reader.object("Missing")
    assert_raises(Undecided) { reader.object("B") }
    assert_raises(Undecided) { reader.object("C") }
  end

  def test_strings_reads_one_string_or_a_list_of_strings
    reader = Reader.new({ "A" => "x", "B" => [ "x", "y" ], "C" => [ "x", { "Ref" => "P" } ], "D" => 1 })

    assert_equal [ "x" ], reader.strings("A")
    assert_equal [ "x", "y" ], reader.strings("B")
    assert_equal [], reader.strings("Missing")
    assert_raises(Undecided) { reader.strings("C") }
    assert_raises(Undecided) { reader.strings("D") }
  end

  def test_keys_reads_the_keys_of_an_object
    # The keys are read even when one of the values is dynamic: only the keys are returned.
    reader = Reader.new({ "A" => { "DB_PASSWORD" => "x", "with a dot.in it" => { "Ref" => "P" } }, "B" => [ "x" ] })

    assert_equal [ "DB_PASSWORD", "with a dot.in it" ], reader.keys("A")
    assert_equal [], reader.keys("Missing")
    assert_raises(Undecided) { reader.keys("B") }
  end

  def test_entry_reads_one_named_value_of_a_map
    reader = Reader.new({ "V" => { "A" => 1, "with a dot.in it" => 2, "B" => { "Ref" => "P" }, "C" => { "Ref" => "AWS::NoValue" } } })

    assert_equal 1, reader.entry("V", "A")
    assert_equal 2, reader.entry("V", "with a dot.in it")
    assert_nil reader.entry("V", "C")
    assert_nil reader.entry("V", "Z")
    assert_nil reader.entry("Missing", "A")
    error = assert_raises(Undecided) { reader.entry("V", "B") }
    assert_equal "V.B", error.path
  end

  def test_item_paths_lists_a_list_and_takes_one_object_as_a_list_of_one
    reader = Reader.new({ "L" => [ { "a" => 1 }, { "b" => 2 } ], "O" => { "a" => 1 }, "S" => "x" })

    assert_equal [ "L[0]", "L[1]" ], reader.item_paths("L")
    assert_equal [ "O" ], reader.item_paths("O")
    assert_equal [], reader.item_paths("Missing")
    assert_raises(Undecided) { reader.item_paths("S") }
  end

  def test_at_and_sub_position_a_reader
    reader = Reader.new({ "Doc" => { "Statement" => [ { "Effect" => "Allow" } ] } })

    statement = reader.at("Doc.Statement[0]")
    assert_equal "Allow", statement.string("Effect")
    assert_equal "Doc.Statement[0].Effect", statement.full_path("Effect")

    parsed = reader.sub("Doc.String", { "Statement" => { "Effect" => "Deny" } })
    assert_equal "Deny", parsed.at("Statement").string("Effect")
    assert_equal "Doc.String.Statement.Effect", parsed.at("Statement").full_path("Effect")
  end

  def test_a_path_that_is_not_a_path_is_undecided
    error = assert_raises(Undecided) { Reader.new({}).raw("A[B") }

    assert_equal "A[B", error.path
  end

  # --- the defect the lead found twice in another track

  def test_nothing_in_the_component_replaces_object_hash
    classes = classes_under(RubyCdk::Nag)
    assert_includes classes.map(&:name), "RubyCdk::Nag::Reader"

    classes.reject { |klass| klass < Data }.each { |klass| assert_object_hash_is_intact(klass) }

    config = RubyCdk::Nag::Config.default
    objects = [
      Reader.new({}),
      Reader.new(nil),
      RubyCdk::Nag::Report.new,
      config,
      RubyCdk::Nag::Engine.new,
      RubyCdk::Nag::Rules::EbsVolumeEncrypted.new({}, logical_id: "Disk", config: config)
    ]
    objects.each do |object|
      assert_equal(:key, { object => :key }[object], "#{object.class} cannot be a Hash key")
      assert_equal(1, [ object, object ].uniq.length, "#{object.class} cannot be de-duplicated")
    end
  end

  private

  def assert_object_hash_is_intact(klass)
    assert_equal(Kernel, klass.instance_method(:hash).owner, "#{klass} defines hash itself: such an object cannot be a Hash key")
  end

  def classes_under(namespace)
    namespace.constants(false).map { |name| namespace.const_get(name, false) }.flat_map { |constant|
      case constant
      when Class then [ constant ]
      when Module then classes_under(constant)
      else []
      end
    }
  end
end
