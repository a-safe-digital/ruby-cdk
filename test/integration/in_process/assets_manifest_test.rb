# frozen_string_literal: true

# Crosses three components (the tree, the assets, the pipeline) and the hook
# that the umbrella registers between the last two, so it runs in process here
# and not under one component's unit tests.

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"

class AssetsManifestTest < Minitest::Test
  TARGET = RubyCdk::Env.new(account: "111122223333", region: "eu-central-1")
  BUCKET = "ruby-cdk-assets-111122223333-eu-central-1"

  def setup
    RubyCdk::App.reset!
    @dir = Dir.mktmpdir("ruby-cdk-assets-manifest")
  end

  def teardown
    RubyCdk::App.reset!
    FileUtils.remove_entry(@dir)
  end

  def test_the_manifest_lists_the_assets_a_stack_resolved
    files = File.join(@dir, "lambda")
    FileUtils.mkdir_p(files)
    File.write(File.join(files, "index.rb"), "puts 1\n")
    hash = RubyCdk::Assets::Hasher.asset_hash(files)

    app = RubyCdk::App.new(env: TARGET, out_dir: File.join(@dir, "out")) do |app|
      RubyCdk::Stack.new(app, "Web") do
        resource("Function", "AWS::Lambda::Function", properties: { "Code" => asset.zip(files).s3_location })
      end
      RubyCdk::Stack.new(app, "Plain")
    end

    manifest = app.synth

    web, plain = manifest.entries
    assert_equal [ "sha256:#{hash}" ], web.assets
    assert_equal [], plain.assets, "a stack that declared no asset lists one"

    template = JSON.parse(File.read(File.join(app.out_dir, "Web.template.json")))
    code = template.fetch("Resources").fetch("Function").fetch("Properties").fetch("Code")
    assert_equal({ "S3Bucket" => BUCKET, "S3Key" => "#{hash}.zip" }, code)

    written = JSON.parse(File.read(manifest.path))
    assert_equal [ "sha256:#{hash}" ], written.fetch("stacks").first.fetch("assets")

    # Which model was consulted, from the hook the umbrella registers.
    assert_equal RubyCdk::Schema.schema_version, written.fetch("schema_version")
    assert_match(/\Aresource specification [\d.]+, model sha256:[0-9a-f]{64}, model format \d+\z/, written.fetch("schema_version"))
  end

  def test_an_asset_that_cannot_be_read_is_one_issue_among_the_others
    nowhere = File.join(@dir, "nowhere")

    app = RubyCdk::App.new(env: TARGET, out_dir: File.join(@dir, "out")) do |app|
      RubyCdk::Stack.new(app, "Web") do
        resource("Function", "AWS::Lambda::Function", properties: { "Code" => asset.zip(nowhere).s3_location })
        output("Built", value: Time.now)
      end
    end

    error = assert_raises(RubyCdk::ValidationError) { app.synth }

    found = error.issues.to_h { |issue| [ issue.path, issue.message ] }
    assert_match(/Cannot find asset directory/, found.fetch("Resources.Function.Properties.Code"))
    assert_match(/Time is not a value/, found.fetch("Outputs.Built.Value"), "the other problem was not collected with it")
    refute Dir.exist?(app.out_dir), "something was written although synthesis failed"
  end
end
