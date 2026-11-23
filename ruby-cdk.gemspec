# frozen_string_literal: true

require_relative "lib/ruby_cdk/version"

Gem::Specification.new do |spec|
  spec.name = "ruby-cdk"
  spec.version = RubyCdk::VERSION
  spec.authors = [ "A-Safe Digital" ]

  spec.summary = "AWS CDK-style infrastructure as code in pure Ruby, deployed through the AWS SDK for Ruby."
  spec.description = "Define AWS infrastructure as Ruby code, synthesize byte-identical CloudFormation " \
    "templates, validate them at synth against the schemas AWS publishes, and deploy them through " \
    "change sets with the AWS SDK for Ruby. A pure Ruby toolchain: no JavaScript runtime anywhere."
  spec.homepage = "https://github.com/a-safe-digital/ruby-cdk"
  spec.license = "MIT"
  spec.metadata = {
    # The homepage is above; repeating it here would only make rubygems.org choose between two.
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.required_ruby_version = ">= 4.0.0"

  # Runtime dependencies. Adding one needs the owner's approval and an entry in the
  # dependency list of the architecture document.
  spec.add_dependency "aws-sdk-cloudformation", "~> 1.0"
  spec.add_dependency "aws-sdk-s3", "~> 1.0"
  spec.add_dependency "thor", "~> 1.4"
  spec.add_dependency "rubyzip", "~> 3.0"

  spec.files = Dir["lib/**/*.rb", "exe/*", "data/**/*", "sig/**/*.rbs"].sort
  spec.files += %w[CHANGELOG.md LICENSE README.md THIRD_PARTY_NOTICES.md].select { |name| File.exist?(File.expand_path(name, __dir__)) }

  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}).map { |path| File.basename(path) }
  spec.require_paths = [ "lib" ]
end
