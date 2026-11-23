# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies are declared in ruby-cdk.gemspec. Adding one needs the owner's approval.
gemspec

gem "minitest", "~> 5.25"
gem "rake"

# Line coverage; the floor is enforced by `rake coverage:check`.
gem "simplecov", "~> 0.22", group: :coverage, require: false

# Style.
gem "rubocop-rails-omakase", group: :style, require: false

# Types. A group of their own, so a platform without a Sorbet build installs without them.
group :types do
  gem "sorbet", require: false
  gem "tapioca", require: false
end
