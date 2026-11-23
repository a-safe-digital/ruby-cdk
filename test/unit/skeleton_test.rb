# frozen_string_literal: true

require "test_helper"
require "ruby_cdk/deploy"

# Temporary. Every method that a later wave implements still answers
# NotImplementedError. As each is implemented its own tests replace the probe.
# Delete this file when none is left.
class SkeletonTest < Minitest::Test
  def test_every_unimplemented_method_says_so
    probes = [
      -> { RubyCdk::Construct.new(nil, "Node") },
      -> { RubyCdk::Construct.allocate.children },
      -> { RubyCdk::Construct.allocate.add(Object.new) },
      -> { RubyCdk::Construct.allocate.resource("R", "AWS::S3::Bucket") },
      -> { RubyCdk::Construct.allocate.stack },
      -> { RubyCdk::App.current },
      -> { RubyCdk::App.build!(app_file: "cdk.rb") },
      -> { RubyCdk::App.new },
      -> { RubyCdk::App.allocate.synth },
      -> { RubyCdk::Stack.allocate.parameter("P", type: "String") },
      -> { RubyCdk::Stack.allocate.output("O", value: 1) },
      -> { RubyCdk::Stack.allocate.export("O", value: 1) },
      -> { RubyCdk::Stack.allocate.export_name("O") },
      -> { RubyCdk::Stack.allocate.mapping("M", {}) },
      -> { RubyCdk::Stack.allocate.condition("C", {}) },
      -> { RubyCdk::Stack.allocate.asset },
      -> { RubyCdk::Stack.allocate.unique_name },
      -> { RubyCdk::Stack.allocate.add_dependency(nil) },
      -> { RubyCdk::Stack.allocate.to_template },
      -> { RubyCdk::Cfn::Resource.new(nil, "R", type: "AWS::S3::Bucket") },
      -> { RubyCdk::Assets::Builder.new(nil).zip("dir") },
      -> { RubyCdk::Assets::Zip.new(hash: "h", key: "k").bucket },
      -> { RubyCdk::Deploy::Deployer.new(client: nil, store: nil, output: nil) },
      -> { RubyCdk::Deploy::Deployer.allocate.deploy(stack: nil, template: nil, identity: nil, options: nil) },
      -> { RubyCdk::Deploy::Deployer.allocate.destroy(stack_name: "s", identity: nil, options: nil) }
    ]

    output = Object.new.extend(RubyCdk::Deploy::Output)
    probes += [
      -> { output.target(account: "1", region: "r", profile: "p") },
      -> { output.changes([]) },
      -> { output.ask("?") },
      -> { output.event(Object.new) },
      -> { output.outputs({}) },
      -> { output.failure("x") },
      -> { output.retained([]) }
    ]

    probes.each_with_index do |probe, index|
      assert_raises(NotImplementedError, "probe #{index} no longer raises: drop it from the list") { probe.call }
    end
  end
end
