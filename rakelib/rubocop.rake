# frozen_string_literal: true

desc "Check style with RuboCop"
task :rubocop do
  sh "bundle", "exec", "rubocop"
end
