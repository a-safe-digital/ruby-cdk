# frozen_string_literal: true

# The security rules. This file is the component's entry: requiring it loads
# the whole rule pack, and nothing else of the gem but the errors.

require_relative "errors"
require_relative "nag/config"
require_relative "nag/engine"

module RubyCdk
  module Nag
    # The rules are v0.1: their ids are fixed, and the pack is listed in Rules::ALL.
    RULES_VERSION = "0.1"

    # The stateful resource types when the configuration names none: the list
    # of architecture section 7 (D-007).
    STATEFUL_TYPES = Config::DEFAULT_STATEFUL_TYPES

    class << self
      # Checks one template, a plain Hash in CloudFormation syntax with the
      # keys as the serializer writes them, and returns a Report.
      #
      # config: a Config, or a Hash written like .ruby-cdk/nag.yml, or nil for
      # the default. path: where the template is, which paths_to_suppress is
      # matched against; a check of one template has no stack name.
      def check(template, config: nil, path: nil)
        Engine.new.check(template, config: config, locations: [ path ])
      end

      # Checks every stack and returns { stack name => Report }, in the order
      # given. templates_by_stack_name maps a stack name to its template.
      #
      # paths optionally maps a stack name to where its template is. The globs
      # of paths_to_suppress are matched against each stack's name and its
      # path.
      def check_all(templates_by_stack_name, config: nil, paths: {})
        unless templates_by_stack_name.is_a?(Hash)
          raise ArgumentError, "templates_by_stack_name must map a stack name to its template, not a #{templates_by_stack_name.class}"
        end

        engine = Engine.new
        templates_by_stack_name.to_h do |stack_name, template|
          [ stack_name, engine.check(template, config: config, locations: [ stack_name, paths[stack_name] ]) ]
        end
      end

      # The configuration of the project whose root is root: its
      # .ruby-cdk/nag.yml, or the default when there is none. Raises
      # ConfigError when the file cannot be understood.
      def load_config(root = ".")
        Config.load(root)
      end

      # Every rule class of the pack, in id order.
      def rules
        Rules::ALL
      end
    end
  end
end
