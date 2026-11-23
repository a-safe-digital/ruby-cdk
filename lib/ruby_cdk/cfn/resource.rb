# frozen_string_literal: true

require_relative "../errors"
require_relative "../core/ids"
require_relative "../core/stateful"
require_relative "../core/construct"

module RubyCdk
  # The tree's contract declares Construct#resource. This is its
  # implementation, in the component that knows what a resource is.
  class Construct
    # Registers an L1 resource in the nearest Stack and returns it.
    #
    # opts are the properties, or properties: holds them under their exact
    # CloudFormation names; the two cannot be combined.
    def resource(id, type, properties: nil, depends_on: [], condition: nil, deletion_policy: nil, update_replace_policy: nil, metadata: {}, **opts)
      if properties && !opts.empty?
        raise UsageError, "resource #{id.inspect} in #{path}: #{Cfn::Resource::BOTH_PROPERTIES}"
      end

      Cfn::Resource.new(self, id, type:, properties: properties || opts, depends_on:, condition:, deletion_policy:, update_replace_policy:, metadata:)
    end
  end

  module Cfn
    # L1: a direct mapping to a CloudFormation resource.
    #
    # Its logical ID is its id when it sits directly in a Stack, and the ids of
    # the constructs around it joined in front of its own otherwise.
    class Resource < Construct
      BOTH_PROPERTIES = "properties: cannot be combined with other keywords. Pass every property as a keyword, or all of them inside properties: { ... }"

      attr_reader :type, :logical_id, :properties, :depends_on, :condition, :deletion_policy, :update_replace_policy, :metadata

      # depends_on: resources, parameters or logical IDs that this resource is
      # created after. condition: a condition of the stack, or its name.
      # deletion_policy: and update_replace_policy: are Symbols or CloudFormation's
      # names, and override what architecture §7 gives the type.
      def initialize(scope, id, type:, properties: nil, depends_on: [], condition: nil, deletion_policy: nil, update_replace_policy: nil, metadata: {}, **opts)
        unless scope.is_a?(Construct)
          raise UsageError, "A resource is created in a Stack or in a Construct: #{id.inspect} got #{scope.inspect} as its scope"
        end
        host = scope.stack
        unless host
          raise UsageError, "A resource is created inside a Stack: #{id.inspect} is created in #{scope.path}, which has no Stack above it"
        end

        where = "resource #{id.inspect} in #{scope.path}"
        @type = resource_type(type, where)
        @properties = properties_hash(properties, opts, where)
        @depends_on = Array(depends_on).map { |target| Core::Ids.logical_id_of(target, "#{where}: depends_on") }
        @condition = Core::Ids.condition_name(condition, "#{where}: condition")
        @deletion_policy = Core::Stateful.deletion_policy(deletion_policy, where:)
        @update_replace_policy = Core::Stateful.update_replace_policy(update_replace_policy, where:)
        unless metadata.is_a?(Hash)
          raise UsageError, "#{where}: metadata takes a Hash, got #{metadata.inspect}"
        end

        @metadata = metadata.dup
        super(scope, id)
        @logical_id = Core::Ids.logical_id(self)
        host.register_resource(self)
      end

      private

      def resource_type(type, where)
        return type if type.is_a?(String) && !type.empty?
        return type.name if type.is_a?(Symbol) && !type.name.empty?

        raise UsageError, "#{where}: the resource type must be a name such as AWS::S3::Bucket, got #{type.inspect}"
      end

      def properties_hash(properties, opts, where)
        raise UsageError, "#{where}: #{BOTH_PROPERTIES}" if properties && !opts.empty?
        unless properties.nil? || properties.is_a?(Hash)
          raise UsageError, "#{where}: properties: takes a Hash, got #{properties.inspect}"
        end

        properties || opts
      end
    end
  end
end
