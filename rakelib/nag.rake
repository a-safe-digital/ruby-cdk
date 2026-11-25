# frozen_string_literal: true

require "rbconfig"
require_relative "../tools/aws_isolation"

desc "Security rules over every template of cdk.out, with .ruby-cdk/nag.yml if there is one"
task :nag do
  # A gate that only ran after a manual synth would never be run, so when
  # cdk.out has no templates the examples are synthesized into it first: no
  # AWS, no credentials, deterministic bytes.
  if Dir["cdk.out/*.template.json"].empty?
    require_relative "../lib/ruby_cdk"
    Dir["examples/*/cdk.rb"].sort.each { |app_file| RubyCdk::App.build!(app_file:) }
    RubyCdk::App.instances.each(&:synth)
  end

  Templates = Dir["cdk.out/*.template.json"].sort
  abort "nag: no templates under cdk.out, and the examples produced none" if Templates.empty?

  require_relative "../lib/ruby_cdk/nag"

  Tools::AwsIsolation.scrub!
  config = RubyCdk::Nag.load_config
  reports = RubyCdk::Nag.check_all(templates_by_stack(Templates), config:)

  reports.each do |stack_name, report|
    puts "nag: #{stack_name}: #{report.violations.length} violation#{"s" if report.violations.length != 1}" \
      "#{", #{report.skipped.length} skipped" unless report.skipped.empty?}"
    report.violations.each do |violation|
      puts "  #{violation.severity} #{violation.rule} #{violation.logical_id}: #{violation.message}"
      puts "    at #{violation.path}" if violation.path && !violation.path.empty?
    end
    report.warnings.each { |warning| puts "  warning: #{warning.message}" }
  end

  failing = reports.select { |_name, report| report.fails?(config.threshold) }
  unless failing.empty?
    puts
    puts "nag: #{failing.length} stack#{"s" if failing.length > 1} fail the #{config.threshold} threshold. " \
      "Suppressions go in .ruby-cdk/nag.yml or in a resource's metadata, each with a reason."
  end
  raise RubyCdk::RulesFailed, "security rules failed" unless failing.empty?
end

def templates_by_stack(paths)
  paths.to_h do |path|
    [ File.basename(path, ".template.json"), JSON.parse(File.read(path)) ]
  end
end
