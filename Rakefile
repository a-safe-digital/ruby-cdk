# frozen_string_literal: true

require "bundler/gem_tasks"

# Rake loads every file in rakelib/ by itself, one file per concern, so that
# parallel tracks never edit the Rakefile itself.

# bundler/gem_tasks ships `rake release`, which would tag and `gem push` to
# rubygems.org in one step. WF-6 keeps both acts with the owner, by hand:
# the tag is pushed by them, and release.yml builds the draft GitHub release
# from it. The stock task is cleared and replaced so nobody reaches the
# wrong button.
if Rake::Task.task_defined?("release")
  Rake::Task["release"].clear
else
  task :release
end
desc "Refuses: tagging and publishing are the owner's manual acts (WF-6, CP-6)"
task :release do
  abort "release: tagging and publishing are the owner's manual acts (WF-6, CP-6). " \
    "Push the tag yourself; .github/workflows/release.yml builds the gem and drafts the GitHub release from it. " \
    "`gem push` to rubygems.org is never automated."
end
