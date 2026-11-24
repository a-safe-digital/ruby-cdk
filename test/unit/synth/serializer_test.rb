# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# The serialization contract of architecture §5, byte for byte.
class SynthSerializerTest < CoreHelpers::TestCase
  Serializer = RubyCdk::Synth::Serializer

  DESCRIPTION = 'The blog: ünïcödé "quoted" <tag> & /slash/'.freeze

  # Every byte of a template with every section in it.
  EXPECTED = <<~JSON
    {
      "AWSTemplateFormatVersion": "2010-09-09",
      "Description": "The blog: ünïcödé \\"quoted\\" <tag> & /slash/",
      "Parameters": {
        "Stage": {
          "Type": "String",
          "Default": "prod",
          "Description": "Where",
          "AllowedValues": [
            "dev",
            "prod"
          ],
          "NoEcho": true
        }
      },
      "Mappings": {
        "Regions": {
          "eu": {
            "west": "eu-west-1"
          }
        }
      },
      "Conditions": {
        "IsProd": {
          "Fn::Equals": [
            {
              "Ref": "Stage"
            },
            "prod"
          ]
        }
      },
      "Resources": {
        "Table": {
          "Type": "AWS::DynamoDB::Table",
          "DependsOn": [
            "Other"
          ],
          "Condition": "IsProd",
          "Metadata": {
            "Team": "Platform"
          },
          "DeletionPolicy": "RetainExceptOnCreate",
          "UpdateReplacePolicy": "Retain",
          "Properties": {
            "KeySchema": [
              {
                "AttributeName": "pk",
                "KeyType": "HASH"
              }
            ]
          }
        },
        "Fn": {
          "Type": "AWS::Lambda::Function",
          "DeletionPolicy": "Retain",
          "UpdateReplacePolicy": "Retain",
          "Properties": {
            "Timeout": 10,
            "MemorySize": 128.5,
            "Tracing": true,
            "Retained": false,
            "Table": {
              "Ref": "Table"
            },
            "Role": {
              "Fn::GetAtt": [
                "Table",
                "Arn"
              ]
            },
            "Url": {
              "Fn::Join": [
                ".",
                [
                  "https:",
                  {
                    "Ref": "Table"
                  }
                ]
              ]
            }
          }
        }
      },
      "Outputs": {
        "TableName": {
          "Value": {
            "Ref": "Table"
          },
          "Export": {
            "Name": "blog-TableName"
          }
        },
        "Url": {
          "Value": "x",
          "Description": "Where it lives"
        }
      },
      "Metadata": {
        "Notes": "none"
      }
    }
  JSON

  def full_stack
    build_stack(stack_options: { description: DESCRIPTION }) do
      parameter("Stage", type: "String", default: "prod", description: "Where", allowed_values: %w[ dev prod ], no_echo: true)
      mapping("Regions", eu: { west: "eu-west-1" })
      condition("IsProd", Fn.equals(Fn.ref("Stage"), "prod"))
      table = resource("Table", "AWS::DynamoDB::Table", "KeySchema" => [ { "AttributeName" => "pk", "KeyType" => "HASH" } ],
        condition: "IsProd", metadata: { "Team" => "Platform" }, depends_on: [ "Other" ])
      resource("Fn", "AWS::Lambda::Function", "Timeout" => 10, "MemorySize" => 128.5, "Tracing" => true, "Retained" => false,
        "Table" => Fn.ref(table), "Role" => Fn.get_att(table, "Arn"), "Url" => Fn.join(".", [ "https:", Fn.ref(table) ]),
        deletion_policy: :retain)
      export("TableName", value: Fn.ref(table))
      output("Url", value: "x", description: "Where it lives")
      add_metadata("Notes", "none")
    end
  end

  def test_a_template_with_every_section_is_these_exact_bytes
    result = RubyCdk::Synth.run(full_stack)

    assert_equal EXPECTED, result.bytes
    assert_equal Encoding::UTF_8, result.bytes.encoding
    assert_equal true, result.bytes.end_with?("}\n")
    assert_equal false, result.bytes.end_with?("}\n\n")
    assert_equal false, result.bytes.include?("\r")

    manifest = full_stack.app.synth
    written = File.join(manifest.out_dir, manifest.entries.first.template)

    assert_equal EXPECTED, File.binread(written).force_encoding(Encoding::UTF_8)
  end

  def test_the_bytes_are_json_that_reads_back_as_the_template
    stack = full_stack
    result = RubyCdk::Synth.run(stack)

    assert_equal result.template, JSON.parse(result.bytes)
    assert_equal result.template, stack.to_template
    assert_equal result.template, RubyCdk::Synth.run(stack).template
    assert_equal result.bytes, RubyCdk::Synth.run(stack).bytes
  end

  def test_what_is_written_is_only_what_json_requires
    # One backslash before the slash, a double quote, a line feed and a tab in the value.
    bytes = Serializer.render({ "Text" => "<b>&'\"\\/é\n\t", "Empty" => [], "None" => {}, "List" => [] })

    assert_equal <<~JSON, bytes
      {
        "Text": "<b>&'\\"\\\\/é\\n\\t",
        "Empty": [],
        "None": {},
        "List": []
      }
    JSON
  end

  def test_integers_are_integers_booleans_are_booleans_and_a_float_is_as_short_as_it_can_be
    bytes = Serializer.call({ "I" => 1, "Big" => 12_345_678_901_234_567_890, "T" => true, "F" => false, "F1" => 1.0, "F2" => 0.1 + 0.2, "F3" => 1e20 })

    assert_equal <<~JSON, bytes
      {
        "I": 1,
        "Big": 12345678901234567890,
        "T": true,
        "F": false,
        "F1": 1.0,
        "F2": 0.30000000000000004,
        "F3": 1e+20
      }
    JSON
  end

  def test_the_sections_and_the_attributes_of_a_resource_are_written_in_a_fixed_order_whatever_their_own
    template = {
      "Metadata" => { "A" => 1 }, "Outputs" => { "O" => { "Value" => 1 } }, "Resources" => {
        "R" => { "Properties" => { "Z" => 1, "A" => 2 }, "UpdateReplacePolicy" => "Retain", "DeletionPolicy" => "Retain", "Metadata" => { "M" => 1 },
          "Condition" => "C", "DependsOn" => [ "X" ], "Type" => "AWS::SNS::Topic", "Extra" => true }
      },
      "Conditions" => { "C" => {} }, "Mappings" => { "M" => {} }, "Parameters" => { "P" => { "Type" => "String" } },
      "Description" => "D", "AWSTemplateFormatVersion" => "2010-09-09", "Transform" => "AWS::Serverless-2016-10-31"
    }

    assert_equal <<~JSON, Serializer.call(template)
      {
        "AWSTemplateFormatVersion": "2010-09-09",
        "Transform": "AWS::Serverless-2016-10-31",
        "Description": "D",
        "Parameters": {
          "P": {
            "Type": "String"
          }
        },
        "Mappings": {
          "M": {}
        },
        "Conditions": {
          "C": {}
        },
        "Resources": {
          "R": {
            "Type": "AWS::SNS::Topic",
            "DependsOn": [
              "X"
            ],
            "Condition": "C",
            "Metadata": {
              "M": 1
            },
            "DeletionPolicy": "Retain",
            "UpdateReplacePolicy": "Retain",
            "Properties": {
              "Z": 1,
              "A": 2
            },
            "Extra": true
          }
        },
        "Outputs": {
          "O": {
            "Value": 1
          }
        },
        "Metadata": {
          "A": 1
        }
      }
    JSON
  end

  def test_a_section_with_nothing_in_it_is_left_out_and_properties_keep_the_order_they_were_written_in
    bytes = Serializer.call({ "Description" => "", "Parameters" => {}, "Resources" => { "R" => { "Type" => "T", "Properties" => {}, "Metadata" => {} } }, "Outputs" => nil })

    assert_equal <<~JSON, bytes
      {
        "Resources": {
          "R": {
            "Type": "T"
          }
        }
      }
    JSON
    assert_equal "{\n  \"Zed\": 1,\n  \"Alpha\": {\n    \"B\": 1,\n    \"A\": 2\n  }\n}\n",
      Serializer.call({ "Zed" => 1, "Alpha" => { "B" => 1, "A" => 2 } })
  end

  def test_an_empty_template_is_two_braces
    assert_equal "{}\n", Serializer.call({})
    assert_equal "{}\n", Serializer.call({ "Description" => nil, "Resources" => [] })
  end

  def test_any_plain_hash_is_written_the_same_way
    manifest = { "ruby_cdk_version" => "1.2.3", "stacks" => [ { "name" => "blog" } ] }

    assert_equal "{\n  \"ruby_cdk_version\": \"1.2.3\",\n  \"stacks\": [\n    {\n      \"name\": \"blog\"\n    }\n  ]\n}\n", Serializer.render(manifest)
    assert_equal "{}\n", Serializer.render({})
  end

  def test_the_transform_section_sits_between_the_format_version_and_the_description_one_transform_as_a_string_several_as_an_array
    one = Serializer.call({ "AWSTemplateFormatVersion" => "2010-09-09", "Transform" => "AWS::LanguageExtensions", "Resources" => { "R" => { "Type" => "T" } } })
    both = Serializer.call({ "Transform" => [ "AWS::Serverless-2016-10-31", "AWS::LanguageExtensions" ], "Description" => "D", "Resources" => {} })

    assert_equal <<~JSON, one
      {
        "AWSTemplateFormatVersion": "2010-09-09",
        "Transform": "AWS::LanguageExtensions",
        "Resources": {
          "R": {
            "Type": "T"
          }
        }
      }
    JSON
    assert_equal %w[Transform Description], JSON.parse(both).keys
  end

  def test_a_template_that_is_not_plain_data_is_an_error_that_says_where_and_not_a_wrong_file
    [ [ { "A" => Object.new }, "A" ], [ { "A" => :symbol }, "A" ], [ { "A" => Float::NAN }, "A" ],
      [ { "A" => Lazy.new { 1 } }, "A" ], [ { "A" => [ { "B" => 2r } ] }, "A[0].B" ], [ { 1 => "one" }, "" ] ].each do |template, place|
      error = assert_raises(RubyCdk::Synth::SerializationError, template.inspect) { Serializer.call(template) }

      assert_match(/\A#{Regexp.escape(place.empty? ? "the template" : place)}: (a key|a [\w:]+) is not plain data: .+ cannot be written\z/, error.message)
      assert_kind_of RubyCdk::Error, error
    end
  end

  def test_the_path_of_a_stack_s_template
    assert_equal "cdk.out/blog.template.json", Serializer.path("cdk.out", "blog")
    assert_equal "/tmp/out/my-stack.template.json", Serializer.path("/tmp/out", "my-stack")
    assert_equal "2010-09-09", Serializer::FORMAT_VERSION
  end
end
