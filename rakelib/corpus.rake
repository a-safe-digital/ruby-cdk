# frozen_string_literal: true

require "tmpdir"
require_relative "../tools/corpus"

# The fetch of the corpus. It is the only part of the corpus tooling that starts a process, and it
# starts nothing but git, through Rake's sh: no package manager, no build, and the CDK is never
# installed or run. The network sees GitHub and nothing else.
#
# aws/aws-cdk is read at main with a shallow partial clone. --depth 1 brings the one commit, a
# blob filter brings no file content with it, and a sparse checkout asks for the template files
# alone. The clone lives in a temporary directory that is gone when the task ends.
module Tools
  module CorpusFetch
    extend Rake::FileUtilsExt

    REPOSITORY = "https://github.com/aws/aws-cdk.git"
    BRANCH = "main"

    # What a fetch answers: the directory that holds the templates, and where they come from.
    Result = Data.define(:directory, :commit, :date, :seconds)

    class << self
      # Fetches every template at BRANCH into a new temporary directory, yields what the fetch
      # answered, and removes the directory however the block ends.
      def with_templates
        Dir.mktmpdir("ruby-cdk-corpus-") { |dir| yield fetch(dir) }
      end

      private

      def fetch(dir)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        clone = File.join(dir, "aws-cdk")

        # --depth 1: the commit that main points to, and nothing older. --filter=blob:none: no
        # file content. --sparse: the first checkout takes the root files only.
        sh "git", "clone", "--depth", "1", "--filter=blob:none", "--single-branch", "--branch", BRANCH,
          "--sparse", REPOSITORY, clone
        # From here on, the only blobs that are fetched are those of the template files.
        sh "git", "-C", clone, "sparse-checkout", "set", "--no-cone", Tools::Corpus::PATTERN

        # The commit, and the day it was made: the date in META.json comes from the commit and not
        # from the clock, so that the same commit gives the same META.json on any day.
        commit, date = output_of(dir, "git", "-C", clone, "log", "-1", "--no-show-signature", "--format=%H%n%cs").split("\n")
        unless commit&.match?(/\A[0-9a-f]{40,64}\z/)
          raise "corpus: could not read the commit that #{BRANCH} of #{REPOSITORY} points to"
        end

        Result.new(
          directory: clone, commit:, date:,
          seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        )
      end

      # The standard output of a command. Rake's sh answers nothing and backticks are refused in
      # this repository, so the output goes to a file.
      def output_of(dir, *command)
        path = File.join(dir, "output")
        sh(*command, out: path)
        File.read(path)
      end
    end
  end
end

namespace :corpus do
  desc "Fetch every template the CDK has synthesized and refresh the committed sample. Network: GitHub"
  task :update do
    Tools::CorpusFetch.with_templates do |fetched|
      templates = Tools::Corpus.templates_in(fetched.directory)
      # A silent "nothing found" would leave the old sample in place next to a META.json that
      # describes no templates.
      if templates.empty?
        abort "corpus: no file of aws/aws-cdk@#{fetched.commit[0, 12]} is named like #{Tools::Corpus::PATTERN}. Has the CDK moved them?"
      end

      report = Tools::Corpus.write_sample(
        destination: Tools::Corpus::FIXTURES,
        templates:,
        commit: fetched.commit,
        date: fetched.date
      )

      corpus = report[:meta].fetch("corpus")
      sample = report[:meta].fetch("sample")
      files = report[:files]
      puts format(
        "corpus: aws/aws-cdk@%s, committed %s: %d templates, %.2f MB, %d resource types, fetched in %.1f s",
        fetched.commit[0, 12], fetched.date, corpus["templates"], corpus["bytes"] / 1e6,
        corpus["resource_types"], fetched.seconds
      )
      # "removed": files that an earlier sample left under test/fixtures/corpus/templates and this
      # one does not hold. That directory is the sample's, so nothing is left there by hand.
      puts format(
        "corpus: sample of %d templates, %.2f MB, %d resource types, %d services: %d written, %d rewritten, " \
          "%d unchanged, %d removed; META.json %s",
        sample["templates"], sample["bytes"] / 1e6, sample["resource_types"], sample["services"].size, files[:written],
        files[:rewritten], files[:unchanged], report[:removed].size, report[:meta_written] ? "rewritten" : "unchanged"
      )
      unless report[:removed].empty?
        shown = report[:removed].first(5)
        shown << "..." if report[:removed].size > shown.size
        puts "corpus: removed #{shown.join(", ")}"
      end
      if corpus["unparseable"].positive?
        puts "corpus: #{corpus["unparseable"]} file(s) that end in #{Tools::Corpus::SUFFIX} are not JSON objects. " \
          "They are counted in META.json and left out of the sample."
      end
    end
  end
end
