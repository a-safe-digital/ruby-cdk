# frozen_string_literal: true

desc "Type-check with Sorbet"
task :typecheck do
  sh "bundle", "exec", "srb", "tc"
end

desc "Regenerate the RBI files of the runtime gems with tapioca"
task "rbi:update" do
  sh "bundle", "exec", "tapioca", "gem",
    "aws-sdk-cloudformation", "aws-sdk-s3", "aws-sdk-core", "aws-sigv4", "aws-partitions",
    "aws-eventstream", "jmespath", "thor", "rubyzip", "rake", "--no-doc"
end
