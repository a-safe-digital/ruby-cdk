# frozen_string_literal: true

desc "Everything that must pass before a commit"
task default: %i[test coverage:check rubocop typecheck purity]
