# frozen_string_literal: true

module RubyCdk
  module Cli
    # The two options that are written as KEY=VALUE pairs: --parameters and
    # --tags. "k=v,k2=v2" is one string once Thor has read it.
    module Pairs
      # The pairs as a Hash of Strings. An option that was not given, or that
      # is blank, is no pairs. Raises Cli::Usage for anything that is not
      # KEY=VALUE and for a key given twice. option names the option and
      # command the command, for the line that says what to run next.
      def self.parse(text, option:, command:)
        return {} if text.nil? || text.strip.empty?

        text.split(",", -1).each_with_object({}) do |item, pairs|
          key, value = item.split("=", 2)
          key = key&.strip
          unless value && key && !key.empty?
            Kernel.raise Usage.new("#{option} takes KEY=VALUE pairs separated by commas, and #{item.strip.inspect} is not one",
              next_step: "Run `ruby-cdk #{command}` again with #{option} KEY=VALUE,KEY=VALUE.")
          end
          if pairs.key?(key)
            Kernel.raise Usage.new("#{option} names #{key.inspect} twice: #{pairs[key].inspect} and #{value.to_s.inspect}",
              next_step: "Run `ruby-cdk #{command}` again with #{key}=VALUE once.")
          end

          pairs[key] = value.to_s
        end
      end
    end
  end
end
