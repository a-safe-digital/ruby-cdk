# frozen_string_literal: true

require "digest"
require_relative "construct"
require_relative "elements"
require_relative "stateful"

module RubyCdk
  # One template. Built from a block evaluated in its own context, or from a
  # subclass that overrides build.
  class Stack < Construct
    # CloudFormation's rule for a stack name: a letter, then letters, digits and hyphens.
    NAME_PATTERN = /\A[A-Za-z][A-Za-z0-9-]*\z/
    MAX_NAME_LENGTH = 128

    # unique_name ends with this many hex characters of a SHA-256.
    UNIQUE_NAME_HASH_LENGTH = 8

    # Shorter than this, no name is a valid S3 bucket name.
    MIN_UNIQUE_NAME_LENGTH = 3
    DEFAULT_UNIQUE_NAME_MAX_LENGTH = 64

    attr_reader :stack_name, :termination_protection, :app, :env, :description, :tags, :stateful_default

    def initialize(scope, id, env: nil, description: nil, tags: {}, stateful_default: nil, termination_protection: false, &block)
      unless scope.is_a?(App)
        raise UsageError, "A Stack is created in an App: Stack.new(app, #{id.inspect}), got #{scope.inspect} as its scope"
      end
      if env && !env.is_a?(Env)
        raise UsageError, "Stack #{id.inspect}: env must be a RubyCdk::Env, got #{env.inspect}"
      end

      super(scope, id)
      @app = scope
      @stack_name = "#{scope.stack_name_prefix}#{self.id}"
      @env = env || scope.env
      @description = description && text(description, "description")
      @tags = tag_hash(tags)
      @stateful_default = Core::Stateful.validate_default!(stateful_default || scope.stateful_default)
      @termination_protection = termination_protection ? true : false

      @resources = []
      @parameters = {}
      @outputs = {}
      @mappings = {}
      @conditions = {}
      @metadata = {}
      @dependencies = []

      if block
        instance_eval(&block)
      else
        build
      end
    end

    # What a subclass defines instead of passing a block.
    def build
    end

    def parameter(id, type:, default: nil, description: nil, allowed_values: nil, no_echo: false)
      declare(@parameters, id) do |name|
        Core::Parameter.new(self, name, type:, default:, description:, allowed_values:, no_echo:)
      end
    end

    def output(id, value:, description: nil, export: false, condition: nil)
      name_of_condition = Core::Ids.condition_name(condition, "#{path}: output #{id.inspect}")
      declare(@outputs, id) do |name|
        Core::Output.new(self, name, value:, description:, export:, condition: name_of_condition)
      end
    end

    # An output whose Export name is export_name(id).
    def export(id, value:, description: nil)
      output(id, value:, description:, export: true)
    end

    # "#{stack_name}-#{id}"
    def export_name(id)
      "#{stack_name}-#{Core::Ids.validate_id!(id, scope: self)}"
    end

    def mapping(id, hash)
      declare(@mappings, id) { |name| Core::Mapping.new(self, name, hash) }
    end

    def condition(id, fn)
      declare(@conditions, id) { |name| Core::Condition.new(self, name, fn) }
    end

    # Adds to the template's Metadata section.
    def add_metadata(key, value)
      @metadata[text(key, "metadata key")] = value
      self
    end

    # The builder of the stack's file assets.
    #
    # Declared here because it is the tree's contract. The assets component
    # implements it by reopening this class: core does not depend on assets.
    def asset
      raise NotImplementedError, "added by the assets component"
    end

    # "#{stack_name}-#{suffix}-<hash>": lower-case letters, digits and hyphens.
    # The hash is the first eight hex characters of SHA-256 over
    # "account:region:stack_name:suffix", so the name is stable across deploys
    # and different in another account or region. A name longer than
    # max_length is shortened from the left. Needs a concrete env.
    def unique_name(suffix = nil, max_length: DEFAULT_UNIQUE_NAME_MAX_LENGTH)
      unless env
        raise UsageError, "#{path}: unique_name needs a concrete env. Give the Stack or its App " \
          "env: RubyCdk::Env.new(account:, region:)"
      end
      unless max_length.is_a?(Integer) && max_length >= MIN_UNIQUE_NAME_LENGTH
        raise UsageError, "#{path}: unique_name takes max_length: of at least #{MIN_UNIQUE_NAME_LENGTH}, got #{max_length.inspect}"
      end

      digest = Digest::SHA256.hexdigest("#{env.account}:#{env.region}:#{stack_name}:#{suffix}")[0, UNIQUE_NAME_HASH_LENGTH]
      name = [ stack_name, suffix&.to_s ].compact.map { |part| name_word(part) }.reject(&:empty?).join("-")
      name = "#{name.empty? ? "" : "#{name}-"}#{digest}"
      # Shortened from the left: its last max_length characters.
      name = name[name.length - max_length, max_length] || name if name.length > max_length
      name.delete_prefix("-")
    end

    # Makes this stack deploy after another one.
    def add_dependency(stack)
      raise UsageError, "#{path}: a stack cannot depend on itself" if stack.equal?(self)
      unless stack.is_a?(Stack)
        raise UsageError, "#{path}: add_dependency takes a Stack, got #{stack.inspect}"
      end

      @dependencies << stack unless @dependencies.include?(stack)
      self
    end

    # Runs every phase of architecture §5 except write and returns the template as a Hash.
    #
    # Declared here because it is the tree's contract. The synth component
    # implements it by reopening this class: core does not depend on synth.
    def to_template
      raise NotImplementedError, "added by the synth component"
    end

    # The stacks this one depends on, in the order they were added.
    def dependencies
      @dependencies.dup.freeze
    end

    # What the stack declares, in declaration order. Synthesis reads them.
    def resources
      @resources.dup.freeze
    end

    def parameters
      @parameters.dup.freeze
    end

    def outputs
      @outputs.dup.freeze
    end

    def mappings
      @mappings.dup.freeze
    end

    def conditions
      @conditions.dup.freeze
    end

    def metadata
      @metadata.dup.freeze
    end

    # Adds a resource to this stack's Resources, in creation order. The cfn
    # component calls it when a resource is created in the tree.
    def register_resource(resource)
      @resources << resource
      resource
    end

    private

    def declare(collection, id)
      name = Core::Ids.validate_id!(id, scope: self)
      if collection.key?(name)
        raise UsageError, "#{path} declares #{name.inspect} twice"
      end

      collection[name] = yield name
    end

    # A String or a Symbol, as a String.
    def text(value, what)
      return value if value.is_a?(String)
      return value.name if value.is_a?(Symbol)

      raise UsageError, "#{path}: #{what} must be a String or a Symbol, got #{value.inspect}"
    end

    def tag_hash(tags)
      unless tags.is_a?(Hash)
        raise UsageError, "#{path}: tags takes a Hash, got #{tags.inspect}"
      end

      tags.to_h { |key, value| [ text(key, "tag key"), text(value, "tag value") ] }.freeze
    end

    # Lower-case letters and digits; every run of anything else becomes one hyphen.
    def name_word(part)
      part.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
    end
  end
end
