# frozen_string_literal: true

module RubyCdk
  module Cli
    # The words of a command line, before Thor reads them.
    module Arguments
      # The same words with the command first, when the options were written
      # before it: `ruby-cdk --app app.rb deploy` is how the CDK CLI documents
      # itself (`Usage: cdk -a <cdk-app> COMMAND`, cli.ts in aws-cdk-cli), and
      # Thor only reads a command that comes first.
      #
      # commands are the words that name a command, with their aliases.
      # switches are Thor's class options: an option that takes a value takes
      # the word after it too, and that word may look like a command.
      def self.command_first(argv, commands:, switches:)
        words = argv.dup
        index = 0
        while (word = words[index])
          return words unless word.start_with?("-") || commands.include?(word)
          return [ words.delete_at(index), *words ] if commands.include?(word)
          return words if word == "--"

          index += 1 if takes_value?(word, switches)
          index += 1
        end
        words
      end

      # --out DIR takes the next word; --out=DIR, --quiet and --no-color do not.
      def self.takes_value?(word, switches)
        return false if word.include?("=")

        name = word.split("=", 2).first
        option = switches.values.find do |candidate|
          "--#{candidate.name}" == name || candidate.aliases.include?(name)
        end
        option && option.type != :boolean
      end
    end
  end
end
