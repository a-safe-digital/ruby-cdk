# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/diff"
require "ruby_cdk/deploy/fakes"

module DiffTests
  # The change set of two templates (architecture section 10): what each
  # section reports, what a resource's change says, and where the replacement
  # comes from. The CDK's own diff-template tests are ported beside these, in
  # test/cdk/diff/; this file holds the behaviour that is this tool's own: the
  # schema model as the source of a replacement, the path detail, and the
  # machine object of --json.
  class TemplateDiffTest < Minitest::Test
    def test_the_same_template_twice_is_empty
      template = { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } }
      diff = RubyCdk::Diff.of(template, template)

      assert_predicate diff, :empty?
      assert_equal 0, diff.change_count
      assert_equal [], diff.changes
    end

    def test_a_stack_that_does_not_exist_diffs_against_nothing
      diff = RubyCdk::Diff.of(nil, { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } })

      assert_equal 1, diff.changes.length
      change = diff.changes.first
      assert_equal "Add", change.action
      assert_equal :create, change.impact
      assert_equal "Queue", change.logical_id
    end

    def test_sections_keep_only_what_changed
      old = { "Parameters" => { "Kept" => { "Type" => "String" }, "Old" => { "Type" => "String" } },
              "Outputs" => { "Answer" => { "Value" => "1" } } }
      new = { "Parameters" => { "Kept" => { "Type" => "String" }, "New" => { "Type" => "Number" } },
              "Outputs" => { "Answer" => { "Value" => "2" } } }
      diff = RubyCdk::Diff.of(old, new)

      assert_equal %w[New Old], diff.sections["Parameters"].keys.sort
      assert_nil diff.sections["Parameters"]["Old"].new_value
      assert_equal({ "Value" => "1" }, diff.sections["Outputs"]["Answer"].old_value)
      assert_equal({ "Value" => "2" }, diff.sections["Outputs"]["Answer"].new_value)
      # Two parameter entries (one gone, one new) and the output's new value:
      # Kept is in both and reports nothing.
      assert_equal 3, diff.change_count
    end

    def test_a_changed_property_carrying_its_path_and_both_sides
      old = bucket_with("BucketName" => "a", "AccessControl" => "Private")
      new = bucket_with("BucketName" => "b", "AccessControl" => "PublicRead")
      change = RubyCdk::Diff.of(old, new).changes.first

      assert_equal "Modify", change.action
      assert_equal :replace, change.impact
      paths = change.properties.map { |property| property.path.join(".") }
      assert_equal %w[AccessControl BucketName], paths.sort
      bucket_name = change.properties.find { |property| property.name == "BucketName" }
      assert_equal "a", bucket_name.old_value
      assert_equal "b", bucket_name.new_value
      assert_equal :replace, bucket_name.impact
      assert_equal "True", bucket_name.replacement_field
      access = change.properties.find { |property| property.name == "AccessControl" }
      assert_equal :update, access.impact
      assert_equal "False", access.replacement_field
    end

    def test_a_change_inside_a_nested_path_is_found_and_priced
      key_schema = ->(hash) { { "KeySchema" => [ { "AttributeName" => "id", "KeyType" => hash } ] } }
      old = { "Resources" => { "Table" => { "Type" => "AWS::DynamoDB::Table", "Properties" => key_schema.call("HASH") } } }
      new = { "Resources" => { "Table" => { "Type" => "AWS::DynamoDB::Table", "Properties" => key_schema.call("RANGE") } } }
      change = RubyCdk::Diff.of(old, new).changes.first

      property = change.properties.first
      assert_equal "KeySchema.0.KeyType", property.path.join(".")
      # The model prices the whole path: the KeySchema of a table is create-only
      # even though KeyType alone is mutable (D-005, the specification's answer).
      assert_equal :replace, property.impact
    end

    def test_a_conditional_property_may_replace
      old = instance_with("PrivateDnsNameOptions" => { "EnableResourceNameDnsARecord" => false })
      new = instance_with("PrivateDnsNameOptions" => { "EnableResourceNameDnsARecord" => true })
      change = RubyCdk::Diff.of(old, new).changes.first

      assert_equal :may_replace, change.impact
      assert_equal "Conditional", change.replacement_field
      assert_equal "may be replaced", change.word
    end

    def test_a_type_of_nothing_known_costs_an_update_and_never_a_replacement
      old = { "Resources" => { "Custom" => { "Type" => "Custom::NotKnown", "Properties" => { "Setting" => "1" } } } }
      new = { "Resources" => { "Custom" => { "Type" => "Custom::NotKnown", "Properties" => { "Setting" => "2" } } } }
      change = RubyCdk::Diff.of(old, new).changes.first

      assert_equal :update, change.impact
      assert_equal "False", change.replacement_field
    end

    def test_a_changed_type_replaces
      old = { "Resources" => { "Thing" => { "Type" => "AWS::SNS::Topic" } } }
      new = { "Resources" => { "Thing" => { "Type" => "AWS::SQS::Queue" } } }
      change = RubyCdk::Diff.of(old, new).changes.first

      assert_equal :replace, change.impact
      assert_equal "AWS::SNS::Topic", change.old_type
      assert_equal "AWS::SQS::Queue", change.new_type
      assert_empty change.properties
    end

    def test_a_removed_resource_is_a_destroy_and_a_retained_one_an_orphan
      kept = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "DeletionPolicy" => "Retain" } } }
      plain = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket" } } }

      destroyed = RubyCdk::Diff.of(plain, { "Resources" => {} }).changes.first
      assert_equal "Remove", destroyed.action
      assert_equal :destroy, destroyed.impact

      orphan = RubyCdk::Diff.of(kept, { "Resources" => {} }).changes.first
      assert_equal :orphan, orphan.impact
      assert_equal "orphan", orphan.word
    end

    def test_a_changed_dependson_is_noted_and_costs_an_update
      old = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "DependsOn" => "One" } } }
      new = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "DependsOn" => %w[One Two] } } }
      change = RubyCdk::Diff.of(old, new).changes.first

      assert_equal :update, change.impact
      assert_equal %w[DependsOn Type], change.others.keys.sort
      assert_equal %w[One], change.others["DependsOn"].old_value
      assert_equal %w[One Two], change.others["DependsOn"].new_value
      assert_equal "Type", change.others.keys.find { |name| !change.others[name].different? }
    end

    def test_the_changes_are_ordered_removals_additions_updates
      old = { "Resources" => { "Kept" => { "Type" => "AWS::SQS::Queue" }, "Lost" => { "Type" => "AWS::SQS::Queue" } } }
      new = { "Resources" => { "Kept" => { "Type" => "AWS::SQS::Queue", "Properties" => { "QueueName" => "n" } },
        "Fresh" => { "Type" => "AWS::SQS::Queue" } } }

      assert_equal %w[Lost Fresh Kept], RubyCdk::Diff.of(old, new).changes.map(&:logical_id)
    end

    def test_text_templates_are_parsed_and_never_mutated
      old_text = JSON.generate({ "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue", "DependsOn" => "B" } } })
      new_text = JSON.generate({ "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue", "DependsOn" => %w[A B] } } })
      RubyCdk::Diff.of(old_text, new_text)

      assert_includes old_text, "DependsOn\":\"B"
    end

    def test_a_template_that_is_neither_json_nor_yaml_is_refused
      error = assert_raises RubyCdk::Error do
        RubyCdk::Diff.of("{ not json", { "Resources" => {} })
      end

      assert_match(/neither JSON nor YAML/, error.message)
    end

    def test_the_deployed_template_of_a_stack_names_the_stack_when_it_cannot_be_read
      client = RubyCdk::Deploy::Fakes::CfnClient.new
      client.on(:get_template, "{ broken")

      error = assert_raises RubyCdk::Error do
        RubyCdk::Diff.for_stack(client, "blog", template: { "Resources" => {} }, stack_name: "blog")
      end

      assert_match(/The deployed template of stack blog cannot be read/, error.message)
    end

    def test_for_stack_reads_the_deployed_template_through_the_port
      client = RubyCdk::Deploy::Fakes::CfnClient.new
      client.stack("blog", status: "CREATE_COMPLETE",
        template: JSON.generate({ "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } }))
      template = JSON.generate({ "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue", "Properties" => { "QueueName" => "n" } } } })

      diff = RubyCdk::Diff.for_stack(client, "blog", template:, stack_name: "blog")

      assert_equal %w[Queue], diff.changes.map(&:logical_id)
      assert_equal [ :get_template ], client.calls_to(:get_template).map(&:operation)
      assert_equal "blog", client.calls_to(:get_template).first.args.first
    end

    def test_for_stack_with_an_absent_stack_diffs_against_nothing
      client = RubyCdk::Deploy::Fakes::CfnClient.new
      template = JSON.generate({ "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } })

      diff = RubyCdk::Diff.for_stack(client, "gone", template:, stack_name: "gone")

      assert_equal "Add", diff.changes.first.action
    end

    def test_the_machine_object_of_json_carries_the_whole_diff
      old = { "Description" => "before", "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket",
        "Properties" => { "BucketName" => "a" } } } }
      new = { "Description" => "after", "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket",
        "Properties" => { "BucketName" => "b" } } } }
      object = RubyCdk::Diff.of(old, new, stack_name: "blog").to_h

      assert_equal "blog", object["name"]
      assert_equal true, object["has_changes"]
      assert_equal({ "old" => "before", "new" => "after" }, object["description"])
      resource = object["resources"].first
      assert_equal "Modify", resource["action"]
      assert_equal "True", resource["replacement"]
      assert_equal "replace", resource["impact"]
      assert_equal [ { "path" => "BucketName", "old" => "a", "new" => "b", "replacement" => "True" } ], resource["properties"]
      assert_equal "AWS::S3::Bucket", resource["type"]
    end

    def test_the_machine_object_of_an_empty_diff_has_no_changes
      template = { "Resources" => { "Queue" => { "Type" => "AWS::SQS::Queue" } } }

      assert_equal false, RubyCdk::Diff.of(template, template).to_h["has_changes"]
    end

    def test_the_whole_json_is_deterministic
      old = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "a" } } } }
      new = { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "b" } } } }

      assert_equal RubyCdk::Diff.of(old, new, stack_name: "x").to_h, RubyCdk::Diff.of(old, new, stack_name: "x").to_h
    end

    private

    def bucket_with(properties)
      { "Resources" => { "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => properties } } }
    end

    def instance_with(properties)
      { "Resources" => { "Host" => { "Type" => "AWS::EC2::Instance", "Properties" => properties } } }
    end
  end
end
