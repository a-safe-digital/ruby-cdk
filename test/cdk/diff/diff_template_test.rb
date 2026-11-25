# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/@aws-cdk/cloudformation-diff/test/diff-template.test.ts,
#            in aws/aws-cdk-cli
#   Commit:  eca1b73d682d7763955bec30ab5dd52bbc4327b6 (main, read on 2026-11-25)
#   Licence: Apache-2.0
#
# The origin holds 31 test declarations, 9 of them rows of two test.each
# tables: 31 cases. Each ported one keeps its name, as a comment above the
# test, and what it expects. The scenarios there run fullDiff(current, new)
# and read the TemplateDiff: here they run RubyCdk::Diff.of and read the same
# facts off RubyCdk::Diff::TemplateDiff.
#
# Changed, with nothing else in a case, an input or an outcome:
#   - jest's toBe/toEqual are asserts on the Ruby model: differenceCount is
#     change_count, resources.changes.X is resources[X], isAddition/isRemoval
#     are addition?/removal?, changeImpact is impact with the CDK's names
#     (WILL_REPLACE as :replace), propertyUpdates are the resource's
#     properties (this model carries the changed path rather than the
#     top-level property, so the assert names the path).
#   - "diffing any two arbitrary templates should not crash" runs the
#     fast-check property in the origin. The same property runs here over
#     200 template pairs drawn from a Random seeded once, so the run is
#     deterministic and still draws from shapes the origin's arbitraries
#     draw from (nesting, lists, scalars, intrinsic-looking objects).
#
# Not ported, with the reason, case by case:
#
#   The five describe('propertiesHiddenByChangeSet') cases read
#   propertiesHiddenByChangeSet, which answers which property differences a
#   described change set would hide from the template diff (its issue 2036).
#   This tool diffs the two templates through the port's get_template and
#   prices replacements from the schema model (architecture section 10); it
#   creates no change set to diff against, so there is nothing for the
#   function to answer and nothing to port. The substance the cases protect
#   -- that a value only resolved at deploy time is not reported as a change
#   because its text moved -- is a change-set fact, not a template fact.
#
# Parity: 31 cases in the origin; 26 ported; 5 not ported.

require "test_helper"
require "ruby_cdk/diff"

module CdkDiff
  class DiffTemplateTest < Minitest::Test
    POLICY_DOCUMENT = { "foo" => "Bar" }.freeze # Obviously a fake one!
    BUCKET_POLICY_RESOURCE = {
      "Type" => "AWS::S3::BucketPolicy",
      "Properties" => {
        "PolicyDocument" => POLICY_DOCUMENT,
        "Bucket" => { "Ref" => "BucketResource" }
      }
    }.freeze

    def test_when_there_is_no_difference
      bucket_name = "ShineyBucketName"
      current_template = {
        "Resources" => {
          "BucketPolicyResource" => BUCKET_POLICY_RESOURCE,
          "BucketResource" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => bucket_name } }
        }
      }
      # Making a JSON round-trip, because === is cheating!
      new_template = JSON.parse(JSON.generate(current_template))

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 0, differences.change_count
    end

    def test_when_a_resource_is_created
      current_template = { "Resources" => {} }
      new_template = { "Resources" => { "BucketResource" => { "Type" => "AWS::S3::Bucket" } } }

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 1, differences.change_count
      difference = differences.resources.fetch("BucketResource")
      assert_predicate difference, :addition?
      assert_equal "AWS::S3::Bucket", difference.new_type
      assert_equal :create, difference.impact
    end

    def test_when_a_resource_is_deleted_no_deletion_policy
      current_template = {
        "Resources" => {
          "BucketResource" => { "Type" => "AWS::S3::Bucket" },
          "BucketPolicyResource" => BUCKET_POLICY_RESOURCE
        }
      }
      new_template = { "Resources" => { "BucketResource" => { "Type" => "AWS::S3::Bucket" } } }

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 1, differences.change_count
      difference = differences.resources.fetch("BucketPolicyResource")
      assert_predicate difference, :removal?
      assert_equal "AWS::S3::BucketPolicy", difference.old_type
      assert_equal :destroy, difference.impact
    end

    # test.each ["Retain", "RetainExceptOnCreate"]
    [ "Retain", "RetainExceptOnCreate" ].each do |deletion_policy|
      define_method("test_when_a_resource_is_deleted_deletion_policy_#{deletion_policy.downcase}") do
        current_template = {
          "Resources" => {
            "BucketResource" => { "Type" => "AWS::S3::Bucket" },
            "BucketPolicyResource" => {
              "Type" => "AWS::S3::BucketPolicy",
              "DeletionPolicy" => deletion_policy,
              "Properties" => {
                "PolicyDocument" => POLICY_DOCUMENT,
                "Bucket" => { "Ref" => "BucketResource" }
              }
            }
          }
        }
        new_template = { "Resources" => { "BucketResource" => { "Type" => "AWS::S3::Bucket" } } }

        differences = RubyCdk::Diff.of(current_template, new_template)
        assert_equal 1, differences.change_count
        difference = differences.resources.fetch("BucketPolicyResource")
        assert_predicate difference, :removal?
        assert_equal "AWS::S3::BucketPolicy", difference.old_type
        assert_equal :orphan, difference.impact
      end
    end

    def test_when_a_property_changes
      bucket_name = "ShineyBucketName"
      current_template = {
        "Resources" => {
          "QueueResource" => { "Type" => "AWS::SQS::Queue" },
          "BucketResource" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => bucket_name } }
        }
      }
      new_bucket_name = "#{bucket_name}-v2"
      new_template = {
        "Resources" => {
          "QueueResource" => { "Type" => "AWS::SQS::Queue" },
          "BucketResource" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => new_bucket_name } }
        }
      }

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 1, differences.change_count
      difference = differences.resources.fetch("BucketResource")
      assert_equal "AWS::S3::Bucket", difference.old_type
      property = difference.properties.find { |candidate| candidate.name == "BucketName" }
      assert_equal bucket_name, property.old_value
      assert_equal new_bucket_name, property.new_value
      assert_equal :replace, property.impact
    end

    def test_change_in_dependencies_counts_as_a_simple_update
      # GIVEN
      current_template = {
        "Resources" => {
          "BucketResource" => { "Type" => "AWS::S3::Bucket", "DependsOn" => [ "SomeResource" ] }
        }
      }

      # WHEN
      new_template = {
        "Resources" => {
          "BucketResource" => { "Type" => "AWS::S3::Bucket", "DependsOn" => %w[SomeResource SomeOtherResource] }
        }
      }
      differences = RubyCdk::Diff.of(current_template, new_template)

      # THEN
      assert_equal 1, differences.change_count
      assert_equal :update, differences.resources.fetch("BucketResource").impact
    end

    def test_when_a_property_is_deleted
      bucket_name = "ShineyBucketName"
      current_template = {
        "Resources" => {
          "QueueResource" => { "Type" => "AWS::SQS::Queue" },
          "BucketResource" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => bucket_name } }
        }
      }
      new_template = {
        "Resources" => {
          "QueueResource" => { "Type" => "AWS::SQS::Queue" },
          "BucketResource" => { "Type" => "AWS::S3::Bucket" }
        }
      }

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 1, differences.change_count
      difference = differences.resources.fetch("BucketResource")
      assert_equal "AWS::S3::Bucket", difference.old_type
      property = difference.properties.find { |candidate| candidate.name == "BucketName" }
      assert_equal bucket_name, property.old_value
      assert_nil property.new_value
      assert_equal :replace, property.impact
    end

    def test_when_a_property_is_added
      bucket_name = "ShineyBucketName"
      current_template = {
        "Resources" => {
          "QueueResource" => { "Type" => "AWS::SQS::Queue" },
          "BucketResource" => { "Type" => "AWS::S3::Bucket" }
        }
      }
      new_template = {
        "Resources" => {
          "QueueResource" => { "Type" => "AWS::SQS::Queue" },
          "BucketResource" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => bucket_name } }
        }
      }

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 1, differences.change_count
      difference = differences.resources.fetch("BucketResource")
      assert_equal "AWS::S3::Bucket", difference.old_type
      property = difference.properties.find { |candidate| candidate.name == "BucketName" }
      assert_nil property.old_value
      assert_equal bucket_name, property.new_value
      assert_equal :replace, property.impact
    end

    def test_when_a_resource_type_changed
      current_template = {
        "Resources" => {
          "BucketResource" => { "Type" => "AWS::IAM::Policy", "Properties" => { "PolicyName" => "PolicyName" } }
        }
      }
      new_template = {
        "Resources" => {
          "BucketResource" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "BucketName" } }
        }
      }

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 1, differences.change_count
      difference = differences.resources.fetch("BucketResource")
      refute_nil difference
      assert_equal "AWS::IAM::Policy", difference.old_type
      assert_equal "AWS::S3::Bucket", difference.new_type
      assert_equal :replace, difference.impact
    end

    def test_resource_replacement_is_tracked_through_references
      # If a resource is replaced, then that change shows that references are
      # going to change. This may lead to replacement of downstream resources
      # if the reference is used in an immutable property, and so on.

      # GIVEN
      current_template = {
        "Resources" => {
          "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "Name1" } },
          "Queue" => { "Type" => "AWS::SQS::Queue", "Properties" => { "QueueName" => { "Ref" => "Bucket" } } },
          "Topic" => { "Type" => "AWS::SNS::Topic", "Properties" => { "TopicName" => { "Ref" => "Queue" } } }
        }
      }

      # WHEN
      new_template = {
        "Resources" => {
          "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "Name2" } },
          "Queue" => { "Type" => "AWS::SQS::Queue", "Properties" => { "QueueName" => { "Ref" => "Bucket" } } },
          "Topic" => { "Type" => "AWS::SNS::Topic", "Properties" => { "TopicName" => { "Ref" => "Queue" } } }
        }
      }
      differences = RubyCdk::Diff.of(current_template, new_template)

      # THEN
      assert_equal 3, differences.changes.length
    end

    def test_adding_and_removing_quotes_from_a_numeric_property_causes_no_changes
      cors_rules = ->(max_age) do
        { "CorsConfiguration" => { "CorsRules" => [ { "AllowedMethods" => [ "GET" ], "AllowedOrigins" => [ "*" ], "MaxAge" => max_age } ] } }
      end
      current_template = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => cors_rules.call(10) } } }
      new_template = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => cors_rules.call("10") } } }

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 0, differences.changes.length

      differences = RubyCdk::Diff.of(new_template, current_template)
      assert_equal 0, differences.changes.length
    end

    def test_versions_are_correctly_detected_as_not_numbers
      current_template = {
        "Resources" => {
          "ImageBuilderComponent" => { "Type" => "AWS::ImageBuilder::Component", "Properties" => { "Platform" => "Linux", "Version" => "0.0.1" } }
        }
      }
      new_template = {
        "Resources" => {
          "ImageBuilderComponent" => { "Type" => "AWS::ImageBuilder::Component", "Properties" => { "Platform" => "Linux", "Version" => "0.0.2" } }
        }
      }

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 1, differences.changes.length
    end

    def test_boolean_properties_are_considered_equal_with_their_stringified_counterparts
      # GIVEN
      current_template = {
        "Resources" => {
          "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "PublicAccessBlockConfiguration" => { "BlockPublicAcls" => "true" } } }
        }
      }
      new_template = {
        "Resources" => {
          "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "PublicAccessBlockConfiguration" => { "BlockPublicAcls" => true } } }
        }
      }

      # WHEN
      differences = RubyCdk::Diff.of(current_template, new_template)

      # THEN
      assert_equal 0, differences.change_count
    end

    def test_when_a_property_changes_including_equivalent_dependson
      # GIVEN
      bucket_name = "ShineyBucketName"
      current_template = {
        "Resources" => {
          "BucketResource" => { "Type" => "AWS::S3::Bucket", "DependsOn" => [ "SomeResource" ], "BucketName" => bucket_name }
        }
      }

      # WHEN
      new_bucket_name = "#{bucket_name}-v2"
      new_template = {
        "Resources" => {
          "BucketResource" => { "Type" => "AWS::S3::Bucket", "DependsOn" => [ "SomeResource" ], "BucketName" => new_bucket_name }
        }
      }

      # THEN
      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 1, differences.changes.length

      differences = RubyCdk::Diff.of(new_template, current_template)
      assert_equal 1, differences.changes.length
    end

    # test.each of the seven number-like formats
    [
      [ "0.31.1-prod", "0.31.2-prod" ],
      [ "8.0.5.5.4-identifier", "8.0.5.5.5-identifier" ],
      [ "1.1.1.1", "1.1.1.2" ],
      [ "1.2.3", "1.2.4" ],
      [ "2.2.2.2", "2.2.3.2" ],
      [ "3.3.3.3", "3.4.3.3" ],
      [ "2021-10-23T06:07:08.000Z", "2021-10-23T09:10:11.123Z" ]
    ].each_with_index do |(old_value, new_value), index|
      define_method("test_reports_a_change_when_a_string_property_with_a_number_like_format_changes_from_old_to_new_#{index}") do
        # GIVEN
        current_template = {
          "Resources" => {
            "BucketResource" => { "Type" => "AWS::S3::Bucket", "Properties" => { "Tags" => [ old_value ] } }
          }
        }
        new_template = {
          "Resources" => {
            "BucketResource" => { "Type" => "AWS::S3::Bucket", "Properties" => { "Tags" => [ new_value ] } }
          }
        }
        # WHEN
        differences = RubyCdk::Diff.of(current_template, new_template)

        # THEN
        assert_equal 1, differences.change_count
        difference = differences.resources.fetch("BucketResource")
        assert_equal "AWS::S3::Bucket", difference.old_type
        # The changed path is Tags[0], and this model carries the values of the
        # path rather than the whole list around it.
        property = difference.properties.find { |candidate| candidate.path == [ "Tags", 0 ] }
        assert_equal old_value, property.old_value
        assert_equal new_value, property.new_value
        assert_equal :update, property.impact
      end
    end

    def test_when_a_property_with_a_number_like_format_doesnt_change
      tags = [ "0.31.1-prod", "8.0.5.5.4-identifier", "1.1.1.1", "1.2.3" ]
      current_template = { "Resources" => { "BucketResource" => { "Type" => "AWS::S3::Bucket", "Properties" => { "Tags" => tags } } } }
      new_template = { "Resources" => { "BucketResource" => { "Type" => "AWS::S3::Bucket", "Properties" => { "Tags" => tags } } } }

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 0, differences.change_count
      assert_empty differences.changes
    end

    def test_handles_a_resource_changing_its_type
      current_template = {
        "Resources" => {
          "FunctionApi" => { "Type" => "AWS::Serverless::Api", "Properties" => { "StageName" => "prod" } }
        }
      }
      new_template = {
        "Resources" => {
          "FunctionApi" => { "Type" => "AWS::ApiGateway::RestApi" }
        }
      }

      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 1, differences.change_count
      difference = differences.resources.fetch("FunctionApi")
      refute_predicate difference, :addition?
      refute_predicate difference, :removal?
      assert_equal "AWS::Serverless::Api", difference.old_type
      assert_equal "AWS::ApiGateway::RestApi", difference.new_type
      assert_empty difference.properties
      assert_equal({ "Type" => "AWS::ApiGateway::RestApi" }, difference.new_value)
      assert_equal({ "Properties" => { "StageName" => "prod" }, "Type" => "AWS::Serverless::Api" }, difference.old_value)
    end

    def test_diffing_any_two_arbitrary_templates_should_not_crash
      # We're not interested in making sure we find the right differences here
      # -- just that we're not crashing. The origin runs this property with
      # fast-check; here it runs over 200 pairs from a Random seeded once, so
      # the run is deterministic.
      random = Random.new(20_261_125)
      200.times do
        RubyCdk::Diff.of(arbitrary_template(random), arbitrary_template(random))
      end
    end

    def test_metadata_changes_are_rendered_in_the_diff
      # GIVEN
      current_template = {
        "Resources" => {
          "BucketResource" => {
            "Type" => "AWS::S3::Bucket",
            "BucketName" => "magic-bucket",
            "Metadata" => { "aws:cdk:path" => "/foo/BucketResource" }
          }
        }
      }

      # WHEN
      new_template = {
        "Resources" => {
          "BucketResource" => {
            "Type" => "AWS::S3::Bucket",
            "BucketName" => "magic-bucket",
            "Metadata" => { "aws:cdk:path" => "/bar/BucketResource" }
          }
        }
      }

      # THEN
      differences = RubyCdk::Diff.of(current_template, new_template)
      assert_equal 1, differences.change_count

      differences = RubyCdk::Diff.of(new_template, current_template)
      assert_equal 1, differences.changes.length
    end

    private

    # Shapes the origin's arbitraryTemplate draws from: keys with template-ish
    # names, values that are scalars, lists, or one-key intrinsic objects.
    def arbitrary_template(random)
      resources = 3.times.to_h do |index|
        [ "Resource#{index}", { "Type" => pick(random, TYPES), "Properties" => arbitrary_value(random, 2) } ]
      end
      { "Resources" => resources }
    end

    TYPES = %w[AWS::S3::Bucket AWS::SQS::Queue AWS::SNS::Topic AWS::IAM::Role AWS::CloudFormation::Stack].freeze
    SCALARS = [ "text", 42, true, nil, "0.31.1-prod", "" ].freeze
    INTRINSICS = [ { "Ref" => "Resource0" }, { "Fn::GetAtt" => [ "Resource0", "Arn" ] }, { "Fn::Join" => [ "", [ "a", "b" ] ] } ].freeze

    def pick(random, list)
      list[random.rand(list.length)]
    end

    def arbitrary_value(random, depth)
      shape = random.rand(depth.positive? ? 4 : 2)
      case shape
      when 0 then pick(random, SCALARS)
      when 1 then Array.new(random.rand(3)) { arbitrary_value(random, 0) }
      when 2 then pick(random, INTRINSICS)
      else (random.rand(3) + 1).times.to_h { |index| [ "Key#{index}", arbitrary_value(random, depth - 1) ] }
      end
    end
  end
end
