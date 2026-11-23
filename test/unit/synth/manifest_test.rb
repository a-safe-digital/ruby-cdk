# frozen_string_literal: true

require "test_helper"
require "digest"
require "support/core_helpers"

# What synthesis writes (architecture §12): manifest.json, one file per stack, and nothing when anything is wrong.
class SynthManifestTest < CoreHelpers::TestCase
  Synth = RubyCdk::Synth

  def teardown
    Synth.unregister_manifest_fact(Synth::Manifest::SCHEMA_VERSION_KEY)
    Synth.unregister_entry_fact(Synth::Manifest::ASSETS_KEY)
    Synth.unregister_manifest_fact("generated_by")
    super
  end

  def three_stacks(out: File.join("out", "nested"))
    app = RubyCdk::App.new(out_dir: File.join(dir, out), stack_name_prefix: "demo-")
    net = stack_class do
      vpc = resource("Vpc", "AWS::EC2::VPC", CidrBlock: "10.0.0.0/16")
      export("VpcId", value: Fn.ref(vpc))
    end.new(app, "net", env: TEST_ENV)
    other = RubyCdk::Stack.new(app, "other")
    stack_class do
      resource("Db", "AWS::RDS::DBInstance", "Vpc" => Fn.import_value(net.export_name("VpcId")))
      add_dependency(other)
    end.new(app, "app")
    app
  end

  def test_the_manifest_holds_what_the_architecture_says_in_that_order
    app = three_stacks
    manifest = app.synth
    written = ->(name) { File.binread(File.join(manifest.out_dir, name)) }

    assert_equal <<~JSON, manifest.bytes
      {
        "ruby_cdk_version": "#{RubyCdk::VERSION}",
        "schema_version": null,
        "stacks": [
          {
            "name": "demo-net",
            "template": "demo-net.template.json",
            "template_hash": "sha256:#{Digest::SHA256.hexdigest(written.call("demo-net.template.json"))}",
            "env": {
              "account": "111122223333",
              "region": "eu-west-1"
            },
            "dependencies": [],
            "assets": []
          },
          {
            "name": "demo-other",
            "template": "demo-other.template.json",
            "template_hash": "sha256:#{Digest::SHA256.hexdigest(written.call("demo-other.template.json"))}",
            "env": null,
            "dependencies": [],
            "assets": []
          },
          {
            "name": "demo-app",
            "template": "demo-app.template.json",
            "template_hash": "sha256:#{Digest::SHA256.hexdigest(written.call("demo-app.template.json"))}",
            "env": null,
            "dependencies": [
              "demo-other",
              "demo-net"
            ],
            "assets": []
          }
        ]
      }
    JSON
    assert_equal manifest.bytes, File.binread(manifest.path)
  end

  def test_the_entries
    manifest = three_stacks(out: "out").synth

    assert_kind_of Synth::Manifest, manifest
    assert_equal File.join(dir, "out"), manifest.out_dir
    assert_equal File.join(dir, "out", "manifest.json"), manifest.path
    assert_equal %w[ demo-net demo-other demo-app ], manifest.stacks.map(&:name)
    assert_equal manifest.stacks, manifest.entries
    assert_equal manifest.stacks, manifest.to_a
    assert_predicate manifest.entries, :frozen?
    assert_equal %w[ demo-net.template.json demo-other.template.json demo-app.template.json ], manifest.stacks.map(&:template)
    assert_equal({ "account" => "111122223333", "region" => "eu-west-1" }, manifest.stacks.first.env)
    assert_nil manifest.stacks.last.env
    assert_equal [ "demo-other", "demo-net" ], manifest.stacks.last.dependencies
    assert_equal [], manifest.stacks.first.assets
    assert_equal({ "name" => "demo-net", "template" => "demo-net.template.json",
      "template_hash" => manifest.stacks.first.template_hash, "env" => { "account" => "111122223333", "region" => "eu-west-1" },
      "dependencies" => [], "assets" => [] }, manifest.stacks.first.to_h)
  end

  def test_a_dependency_is_added_when_a_stack_imports_an_export_of_another_by_name
    app = RubyCdk::App.new(out_dir: File.join(dir, "out"))
    producer = stack_class do
      table = resource("Table", "AWS::DynamoDB::Table")
      export("TableName", value: Fn.ref(table))
      output("NotExported", value: 1)
    end.new(app, "producer")
    consumer = stack_class do
      parameter("Name", type: "String")
      resource("Queue", "AWS::SQS::Queue", "QueueName" => Fn.import_value("producer-TableName"))
      resource("Other", "AWS::SQS::Queue", "QueueName" => Fn.import_value("someone-elses-export"))
      resource("Late", "AWS::SQS::Queue", "QueueName" => Fn.import_value(producer.export_name("NotExported")))
      resource("List", "AWS::SQS::Queue", "Tags" => [ { "Value" => Fn.import_value(producer.export_name("TableName")) } ])
    end.new(app, "consumer")

    manifest = app.synth

    assert_equal [], manifest.stacks.first.dependencies
    assert_equal [ "producer" ], manifest.stacks.last.dependencies
  end

  def test_the_template_hash_is_the_sha_256_of_the_file
    manifest = three_stacks(out: "out").synth
    entry = manifest.stacks.first

    assert_match(/\Asha256:[0-9a-f]{64}\z/, entry.template_hash)
    assert_equal "sha256:#{Digest::SHA256.hexdigest(File.binread(File.join(manifest.out_dir, entry.template)))}", entry.template_hash
    refute_equal entry.template_hash, manifest.stacks[1].template_hash
  end

  def test_every_file_is_written_under_the_output_directory_which_is_made
    app = three_stacks
    refute File.exist?(app.out_dir)

    manifest = app.synth

    assert_equal %w[ demo-app.template.json demo-net.template.json demo-other.template.json manifest.json ], Dir.children(manifest.out_dir).sort
  end

  def test_an_app_with_no_stack_writes_a_manifest_with_no_entry
    manifest = build_app.synth

    assert_equal({ "ruby_cdk_version" => RubyCdk::VERSION, "schema_version" => nil, "stacks" => [] }, manifest.to_h)
    assert_equal [ "manifest.json" ], Dir.children(manifest.out_dir)
  end

  def test_nothing_is_written_when_any_stack_is_wrong_and_every_issue_of_every_stack_is_reported
    app = three_stacks
    stack_class { resource("my_table", "AWS::DynamoDB::Table") }.new(app, "broken")
    stack_class { output("bad_output", value: Time.now) }.new(app, "worse")

    error = assert_raises(RubyCdk::ValidationError) { app.synth }

    assert_equal 3, error.issues.length
    assert_equal [ "demo-broken:Resources.my_table", "demo-worse:Outputs.bad_output.Value", "demo-worse:Outputs.bad_output" ],
      error.issues.map(&:path)
    assert_match(/\AV2 demo-broken:Resources\.my_table: /, error.message)
    refute File.exist?(app.out_dir), "synth wrote something although a stack is wrong"

    alone = stack_class { resource("my_table", "AWS::DynamoDB::Table") }.new(build_app, "alone")

    error = assert_raises(RubyCdk::ValidationError) { alone.to_template }

    assert_match(/\AV2 Resources\.my_table: /, error.message)
    refute File.exist?(alone.app.out_dir)
  end

  def test_a_stack_whose_name_is_not_valid_stops_the_whole_app_before_anything_is_written
    app = RubyCdk::App.new(out_dir: File.join(dir, "out"))
    stack_class { resource("Table", "AWS::DynamoDB::Table") }.new(app, "good")
    stack_class { resource("Table", "AWS::DynamoDB::Table") }.new(app, "1bad")

    error = assert_raises(RubyCdk::ValidationError) { app.synth }

    assert_equal "V13 1bad:Stack: the stack name \"1bad\" is not valid: it must start with a letter, " \
      "go on with letters, digits and hyphens, and be at most 128 characters long", error.message
    refute File.exist?(app.out_dir)
  end

  def test_what_other_components_know_is_written_only_when_they_registered_it
    assert_nil build_app.synth.to_h["schema_version"]

    Synth.register_manifest_fact(Synth::Manifest::SCHEMA_VERSION_KEY) { "provider-schema-2026-11-23 / resource-spec-2026-11-19" }
    Synth.register_entry_fact(Synth::Manifest::ASSETS_KEY) { |stack, template| stack.id == "a" ? [ "sha256:#{template["Resources"].keys.length}" ] : [] }
    app = build_app
    stack_class { resource("T", "AWS::SNS::Topic") }.new(app, "a")
    RubyCdk::Stack.new(app, "b")

    manifest = app.synth

    assert_equal "provider-schema-2026-11-23 / resource-spec-2026-11-19", manifest.to_h["schema_version"]
    assert_equal [ [ "sha256:1" ], [] ], manifest.stacks.map(&:assets)
    assert_equal [ "ruby_cdk_version", "schema_version", "stacks" ], manifest.to_h.keys
  end

  def test_a_manifest_fact_may_add_a_key_of_its_own_after_the_fixed_ones
    Synth.register_manifest_fact("generated_by") { "test" }

    manifest = build_app.synth

    assert_equal [ "ruby_cdk_version", "schema_version", "generated_by", "stacks" ], manifest.to_h.keys
  end
end
