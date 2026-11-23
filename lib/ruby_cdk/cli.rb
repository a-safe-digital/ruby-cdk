# frozen_string_literal: true

require "thor"
require_relative "version"

module RubyCdk
  # The command line. One executable, `ruby-cdk`.
  class CLI < Thor
    package_name "ruby-cdk"

    desc "version", "Print the gem version"
    def version
      puts VERSION
    end
    map %w[--version -v] => :version
  end
end
