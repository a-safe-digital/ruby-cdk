# frozen_string_literal: true

require "yaml"
require_relative "report"
require_relative "rules"

module RubyCdk
  module Nag
    # .ruby-cdk/nag.yml says something that cannot be understood, so nothing
    # is assumed: an unknown key, a threshold that is not one of the three, a
    # rule id that no rule has. A usage error, so exit 1.
    class ConfigError < RubyCdk::UsageError; end

    # One suppression written in the configuration file.
    #
    # applies_to narrows it to resources whose logical ID or type matches the
    # glob; nil covers every resource.
    Suppression = Data.define(:id, :reason, :applies_to)

    # What a run of the rules is told: the threshold, what to suppress, which
    # rules run, and which resource types are stateful.
    #
    # The file, at the root of a project:
    #
    #   threshold: medium               # high, medium or low; the default
    #   paths_to_suppress:              # globs on a stack name or path
    #     - "*-sandbox"
    #   suppressions:                   # a suppression without a reason is ignored, with a warning
    #     - id: RC-EC2-001
    #       reason: The bastion is replaced by SSM Session Manager this quarter.
    #       applies_to: "BastionSecurityGroup*"   # optional: a glob on the logical ID or the type
    #   rules:                          # false turns a rule off for the whole project
    #     RC-LOGS-001: false
    #   stateful_types:                 # optional: what RC-STATE-001 reads; the default is the list below
    #     - AWS::S3::Bucket
    #
    # A malformed file is refused with ConfigError. A file that is absent, or
    # empty, is the default configuration.
    #
    # The shape follows cdk-nag (cdklabs/cdk-nag, commit
    # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0), src/nag-pack.ts
    # and README.md "Acknowledging a Rule": a rule is acknowledged with an id
    # and a reason, on one resource or on a whole scope, and one
    # acknowledgement can cover every finding of a rule.
    # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
    # SPDX-License-Identifier: Apache-2.0
    #
    # What changed: cdk-nag has no project file; a pack is configured in
    # code, and its paths are regular expressions where the wave card asks
    # for globs. A finding is addressed by its resource here, with applies_to,
    # where cdk-nag addresses it with "RuleId[FindingId]". A suppression
    # without a reason is ignored with a warning, as the wave card decides.
    class Config
      # The file, under the root of a project.
      FILE = ".ruby-cdk/nag.yml"

      # --fail-on defaults to medium.
      DEFAULT_THRESHOLD = :medium

      # The resource types the CDK retains or snapshots by default, which are
      # retained here too: the list of architecture section 7 (D-007), the same
      # one synthesis applies. RC-STATE-001 reads it when the configuration
      # names none.
      DEFAULT_STATEFUL_TYPES = %w[
        AWS::S3::Bucket
        AWS::DynamoDB::Table
        AWS::Logs::LogGroup
        AWS::KMS::Key
        AWS::EC2::Volume
        AWS::ECR::Repository
        AWS::Cognito::UserPool
        AWS::Kinesis::Stream
        AWS::OpenSearchService::Domain
        AWS::RDS::DBInstance
        AWS::RDS::DBCluster
      ].freeze

      KEYS = %i[threshold paths_to_suppress suppressions rules stateful_types].freeze
      SUPPRESSION_KEYS = %i[id reason applies_to].freeze
      RESOURCE_TYPE = /\AAWS::[A-Za-z0-9]+::[A-Za-z0-9]+\z/

      attr_reader :path, :threshold, :paths_to_suppress, :suppressions, :rules, :stateful_types, :warnings

      # warnings: Array<Warning>, what the file said and was ignored.
      def initialize(path: nil, threshold: DEFAULT_THRESHOLD, paths_to_suppress: [], suppressions: [], rules: {}, stateful_types: DEFAULT_STATEFUL_TYPES, warnings: [])
        @path = path
        @threshold = threshold
        @paths_to_suppress = paths_to_suppress.freeze
        @suppressions = suppressions.freeze
        @rules = rules.freeze
        @stateful_types = stateful_types.freeze
        @warnings = warnings.freeze
        freeze
      end

      class << self
        # Nothing suppressed, every rule on, the default threshold.
        def default
          @default ||= new
        end

        # The configuration of the project whose root is root: its
        # .ruby-cdk/nag.yml, or the default when there is none.
        def load(root = ".")
          from_file(File.expand_path(FILE, root))
        end

        # The configuration in the file at path, or the default when the file
        # does not exist.
        def from_file(path)
          return default unless File.file?(path)

          from_hash(parse(File.read(path), path), path)
        rescue SystemCallError => e
          raise ConfigError, "#{path} cannot be read: #{e.message}"
        end

        # A Config, as it is. A Hash written like the file, with String or
        # Symbol keys, as a Config. nil, the default.
        def coerce(config)
          return config if config.is_a?(Config)
          return default if config.nil?
          raise ArgumentError, "config must be a Nag::Config or a Hash, not a #{config.class}" unless config.is_a?(Hash)

          from_hash(config, nil)
        end

        # The configuration a Hash holds. path names where it came from, for
        # the messages. Raises ConfigError when it cannot be understood.
        def from_hash(hash, path)
          where = path || "the configuration"
          unless hash.is_a?(Hash)
            raise ConfigError, "#{where} must hold the keys #{KEYS.map(&:inspect).join(", ")}, and holds #{hash.class}"
          end

          given = {}
          unknown = []
          hash.each do |key, value|
            if KEYS.include?(key_name(key))
              given[key_name(key)] = value
            else
              unknown << key
            end
          end
          unless unknown.empty?
            raise ConfigError, "#{where} has unknown #{unknown.one? ? "key" : "keys"} #{unknown.map(&:inspect).join(", ")}: the keys are #{KEYS.map(&:inspect).join(", ")}"
          end

          suppressions, warnings = suppressions_of(given[:suppressions], where)
          new(
            path: path,
            threshold: threshold_of(given[:threshold], where),
            paths_to_suppress: globs_of(given[:paths_to_suppress], "#{where}: paths_to_suppress", "a stack name or path"),
            suppressions: suppressions,
            rules: rules_of(given[:rules], where),
            stateful_types: stateful_types_of(given[:stateful_types], where),
            warnings: warnings
          )
        end

        private

        # The key as a Symbol, or nil when it is neither a String nor a Symbol.
        def key_name(key)
          (key.is_a?(String) || key.is_a?(Symbol)) ? key.to_sym : nil
        end

        def parse(text, path)
          YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false, filename: path) || {}
        rescue Psych::SyntaxError => e
          raise ConfigError, "#{path} is not valid YAML: #{e.message}"
        rescue Psych::DisallowedClass, Psych::Exception, ArgumentError => e
          raise ConfigError, "#{path} holds what the file cannot: #{e.message}"
        end

        def threshold_of(value, where)
          return DEFAULT_THRESHOLD if value.nil?

          name = key_name(value)
          name = name.to_s.downcase.to_sym if name
          unless SEVERITIES.include?(name)
            raise ConfigError, "#{where}: threshold #{value.inspect} is not one of #{SEVERITIES.map(&:inspect).join(", ")}"
          end
          name
        end

        # A list of globs, or [] when nothing is given.
        def globs_of(value, where, on)
          return [] if value.nil?
          unless value.is_a?(Array) && value.all? { |glob| glob.is_a?(String) && !glob.strip.empty? }
            raise ConfigError, "#{where} must be a list of globs on #{on}, such as [\"*-sandbox\"]"
          end

          value.each { |glob| check_glob(glob, where) }
          value
        end

        def check_glob(glob, where)
          File.fnmatch?(glob, "", File::FNM_EXTGLOB)
        rescue ArgumentError
          raise ConfigError, "#{where} holds #{glob.inspect}, which is not a glob"
        end

        # [Array<Suppression>, Array<Warning>]. An entry without a reason is
        # not a suppression: it is a warning.
        def suppressions_of(value, where)
          return [ [], [] ] if value.nil?
          unless value.is_a?(Array) && value.all?(Hash)
            raise ConfigError, "#{where}: suppressions must be a list of entries with id, reason and applies_to"
          end

          suppressions = []
          warnings = []
          value.each_with_index do |entry, index|
            at = "#{where}: suppressions[#{index}]"
            unknown = entry.keys.reject { |key| SUPPRESSION_KEYS.include?(key_name(key)) }
            unless unknown.empty?
              raise ConfigError, "#{at} has unknown #{unknown.one? ? "key" : "keys"} #{unknown.map(&:inspect).join(", ")}: the keys are #{SUPPRESSION_KEYS.map(&:inspect).join(", ")}"
            end

            id = value_of(entry, :id)
            unless id.is_a?(String) && Rules.ids.include?(id)
              raise ConfigError, "#{at} names #{id.inspect}, and no rule has that id: the ids are #{Rules.ids.join(", ")}"
            end

            reason = value_of(entry, :reason)
            unless reason.is_a?(String) && !reason.strip.empty?
              warnings << Warning.new(location: at, message: "suppresses #{id} without a reason, and is ignored: a suppression says why it is safe")
              next
            end

            applies_to = value_of(entry, :applies_to)
            unless applies_to.nil?
              raise ConfigError, "#{at}: applies_to must be a glob on a logical ID or a resource type" unless applies_to.is_a?(String) && !applies_to.strip.empty?

              check_glob(applies_to, at)
            end
            suppressions << Suppression.new(id: id, reason: reason.strip, applies_to: applies_to)
          end
          [ suppressions, warnings ]
        end

        def rules_of(value, where)
          return {} if value.nil?
          unless value.is_a?(Hash)
            raise ConfigError, "#{where}: rules must map a rule id to true or false"
          end

          value.to_h do |id, enabled|
            name = key_name(id)&.to_s
            unless Rules.ids.include?(name)
              raise ConfigError, "#{where}: rules names #{id.inspect}, and no rule has that id: the ids are #{Rules.ids.join(", ")}"
            end
            unless enabled == true || enabled == false
              raise ConfigError, "#{where}: rules has #{name} = #{enabled.inspect}, which is not true or false"
            end
            [ name, enabled ]
          end
        end

        def stateful_types_of(value, where)
          return DEFAULT_STATEFUL_TYPES if value.nil?
          unless value.is_a?(Array) && value.all? { |type| type.is_a?(String) && RESOURCE_TYPE.match?(type) }
            raise ConfigError, "#{where}: stateful_types must be a list of resource types, such as [\"AWS::S3::Bucket\"]"
          end
          value
        end

        # The value under the key, whether it is written id or :id.
        def value_of(entry, key)
          entry.fetch(key) { entry[key.to_s] }
        end
      end

      # True when the rule runs in this project.
      def rule_enabled?(id)
        @rules.fetch(id, true)
      end

      # The first glob of paths_to_suppress that matches one of the stack's
      # locations (its name and its path), or nil when none does.
      def suppressed_path(locations)
        @paths_to_suppress.find do |glob|
          locations.compact.any? { |location| File.fnmatch?(glob, location.to_s, File::FNM_EXTGLOB) }
        end
      end

      # The suppression written for this rule that covers the resource, or
      # nil. A suppression with applies_to covers the resource when the glob
      # matches its logical ID or its type.
      def suppression_for(id, logical_id, resource_type)
        @suppressions.find do |suppression|
          next false unless suppression.id == id
          next true if suppression.applies_to.nil?

          [ logical_id, resource_type ].compact.any? { |name| File.fnmatch?(suppression.applies_to, name.to_s, File::FNM_EXTGLOB) }
        end
      end
    end
  end
end
