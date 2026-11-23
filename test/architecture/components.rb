# frozen_string_literal: true

# The component map, in the form a test can enforce. It is the executable version
# of the architecture's component section: what each component owns, what it may
# depend on, which gems it may load, and from which entry file it is loaded alone.
#
# What a component may name is not listed here: the boundary test finds it in the
# code, since a constant belongs to whichever component's file defines it.
#
# test/architecture/component_boundaries_test.rb enforces it. Adding a dependency
# means changing this file, with a reason, in the same commit. A component gets its
# row when it is built, not before: the map lists what exists.
module Architecture
  Component = Data.define(:name, :layer, :entry, :paths, :depends_on, :gems, :purpose)

  # Libraries that ship with Ruby. Every component may load them without saying
  # so: they are part of the language, not a dependency. What a row lists under
  # gems is everything else, which has to be named to be loaded.
  STDLIB = %w[date digest fileutils json pathname securerandom set stringio tempfile time uri yaml zlib].freeze

  # Paths are relative to lib/.
  COMPONENTS = [
    # Layer 0: nothing inside the gem below it.
    Component.new(name: :errors, layer: 0, entry: "ruby_cdk/errors", paths: %w[ruby_cdk/errors.rb], depends_on: [], gems: [],
      purpose: "The error classes, one per exit code, and Issue."),
    Component.new(name: :values, layer: 0, entry: "ruby_cdk/values", paths: %w[ruby_cdk/fn.rb ruby_cdk/lazy.rb ruby_cdk/env.rb ruby_cdk/values.rb], depends_on: %i[errors], gems: [],
      purpose: "The CloudFormation functions (Fn), the deferred value (Lazy) and a concrete target (Env)."),
    Component.new(name: :version, layer: 0, entry: "ruby_cdk/version", paths: %w[ruby_cdk/version.rb], depends_on: [], gems: [],
      purpose: "The gem's version, on its own so that the gemspec and the command line can read it."),

    # Layer 1: depends only on layer 0.
    Component.new(name: :core, layer: 1, entry: "ruby_cdk/core", paths: %w[ruby_cdk/core.rb ruby_cdk/core], depends_on: %i[errors values], gems: [],
      purpose: "The tree: Construct, Stack, App, ids and the retention defaults. It knows nothing of assets, validation or deployment."),
    Component.new(name: :schema, layer: 1, entry: "ruby_cdk/schema", depends_on: %i[errors], gems: %w[zip net/http],
      paths: %w[ruby_cdk/schema.rb ruby_cdk/schema/schema.rb ruby_cdk/schema/type_schema.rb ruby_cdk/schema/property_schema.rb ruby_cdk/schema/sources.rb ruby_cdk/schema/sources],
      purpose: "What AWS resources look like: the vendored model, its loader, and the rake task that rebuilds it from the two published sources."),
    Component.new(name: :ports, layer: 1, entry: "ruby_cdk/deploy/ports", paths: %w[ruby_cdk/deploy/ports.rb], depends_on: [], gems: [],
      purpose: "The two interfaces to the outside (CloudFormation and the object store), the output interface, and the values that cross them."),
    Component.new(name: :test_kit, layer: 1, entry: "ruby_cdk/test", paths: %w[ruby_cdk/test.rb ruby_cdk/test], depends_on: [], gems: [],
      purpose: "RubyCdk::Test: the matchers and template queries a user's tests are written with."),
    Component.new(name: :nag, layer: 1, entry: "ruby_cdk/nag", paths: %w[ruby_cdk/nag.rb ruby_cdk/nag], depends_on: %i[errors], gems: [],
      purpose: "The security rules, over a template as a plain Hash."),

    # Layer 2: depends on layers 0 and 1.
    Component.new(name: :cfn, layer: 2, entry: "ruby_cdk/cfn", paths: %w[ruby_cdk/cfn.rb ruby_cdk/cfn], depends_on: %i[errors values core], gems: [],
      purpose: "L1: the direct mapping to a CloudFormation resource."),
    Component.new(name: :synth, layer: 2, entry: "ruby_cdk/synth", paths: %w[ruby_cdk/synth.rb ruby_cdk/synth], depends_on: %i[errors values version core], gems: [],
      purpose: "The pipeline: prepare, resolve, the normalize and validate hooks, serialize, write, manifest (which names the gem version). It learns the normalizer, the rules and the assets only through what is registered with it."),
    Component.new(name: :assets, layer: 2, entry: "ruby_cdk/assets", paths: %w[ruby_cdk/assets.rb ruby_cdk/assets], depends_on: %i[errors values core ports], gems: %w[zip],
      purpose: "File assets: the manifest hash, the deterministic zip, the record, the builder and the upload through the object-store port. It adds Stack#asset to the tree; the tree never names it."),
    Component.new(name: :deploy, layer: 2, entry: "ruby_cdk/deploy", depends_on: %i[errors ports], gems: [],
      paths: %w[ruby_cdk/deploy.rb ruby_cdk/deploy/errors.rb ruby_cdk/deploy/poller.rb ruby_cdk/deploy/capabilities.rb ruby_cdk/deploy/parameters.rb
        ruby_cdk/deploy/deployer.rb ruby_cdk/deploy/states.rb ruby_cdk/deploy/fakes.rb ruby_cdk/deploy/output],
      purpose: "The engine: the six stack states, deploy and destroy through the ports, the scriptable fakes."),

    # Layer 3: the only place that knows the AWS SDK.
    Component.new(name: :adapters, layer: 3, entry: "ruby_cdk/deploy/sdk_adapters", paths: %w[ruby_cdk/deploy/sdk_adapters.rb], depends_on: %i[errors ports], gems: %w[aws-sdk-cloudformation aws-sdk-s3 aws-sdk-core],
      purpose: "The AWS SDK behind the two ports."),

    # Layer 4: composes components; owns no logic of its own.
    Component.new(name: :cli, layer: 4, entry: "ruby_cdk/cli", paths: %w[ruby_cdk/cli.rb ruby_cdk/cli], gems: %w[thor],
      depends_on: %i[errors values version core cfn synth assets deploy adapters],
      purpose: "The command line: options, the app file, exit codes. Calls components; implements nothing.")
  ].freeze

  # The umbrella: what `require "ruby-cdk"` loads. No component may require it.
  UMBRELLA = %w[ruby_cdk.rb ruby-cdk.rb].freeze

  # A constant belongs to the component whose file defines it, and a component
  # reads only the constants that it or its dependencies define. Ports and the
  # deploy engine therefore share the name RubyCdk::Deploy without being open to
  # each other: the adapter may read RubyCdk::Deploy::StackStatus, which ports
  # defines, and may not read RubyCdk::Deploy::Deployer, which the engine does.

  # Components in layers below this one must never reach the AWS SDK.
  AWS_SDK_FROM_LAYER = 3

  class << self
    def find(name)
      COMPONENTS.find { |component| component.name == name }
    end

    # The component that owns a file, by its path relative to lib/, with or without .rb.
    # nil for the umbrella and for files no component owns.
    def owner_of(path)
      bare = path.delete_suffix(".rb")
      COMPONENTS.find do |component|
        component.paths.any? { |owned| bare == owned.delete_suffix(".rb") || bare.start_with?("#{owned}/") }
      end
    end

    # A component and everything it may reach, directly or through its dependencies.
    def closure(name)
      seen = []
      frontier = [ name ]
      until frontier.empty?
        current = frontier.pop
        next if seen.include?(current)

        seen << current
        frontier.concat(find(current).depends_on)
      end
      seen
    end

    def entry_path(component)
      File.join(LIB, "#{component.entry}.rb")
    end

    def files_of(component)
      component.paths.flat_map do |relative|
        full = File.join(LIB, relative)
        if File.directory?(full)
          Dir[File.join(full, "**", "*.rb")].sort
        elsif File.file?(full)
          [ full ]
        else
          []
        end
      end
    end
  end

  LIB = File.expand_path("../../lib", __dir__)
end
