# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "ids"

module RubyCdk
  # Any node in the tree. Building is immediate: a construct exists as soon as
  # its constructor returns.
  class Construct
    # So that `Fn.ref` resolves inside any construct or Stack subclass.
    Fn = RubyCdk::Fn

    # Letters, digits, underscore and hyphen. Logical IDs are narrower: alphanumeric only.
    ID_PATTERN = /\A[A-Za-z0-9_-]+\z/

    # CloudFormation limits a logical name to 255 characters.
    MAX_ID_LENGTH = 255

    attr_reader :scope, :id, :path

    # scope is an App, a Stack or another Construct.
    def initialize(scope, id)
      unless scope.is_a?(Construct) || (scope.nil? && is_a?(App))
        raise UsageError, "#{self.class} needs a scope: an App, a Stack or a Construct, got #{scope.inspect}"
      end

      @scope = scope
      @id = Core::Ids.validate_id!(id, scope: scope)
      @path = scope ? "#{scope.path}/#{@id}" : @id
      @children = []
      @prepared = false
      scope.add(self) if scope
    end

    # The nodes added to this one, in the order they were created.
    def children
      @children.dup.freeze
    end

    # Validates the id and rejects duplicates among siblings. Returns node.
    def add(node)
      unless node.is_a?(Construct)
        raise UsageError, "#{path} takes a Construct as a child, got #{node.inspect}"
      end

      Core::Ids.validate_id!(node.id, scope: self)
      if @children.any? { |child| child.id == node.id }
        raise UsageError, "There is already a construct with id \"#{node.id}\" in #{path}"
      end

      @children << node
      node
    end

    # The nearest enclosing Stack, or nil when there is none.
    def stack
      node = self
      node = node.scope while node && !node.is_a?(Stack)
      node
    end

    # Hook, children first. Curated constructs add implicit resources here.
    def prepare
    end

    # Runs the prepare hook on this node and on everything under it, each node
    # once and children before their parent. Synthesis calls it; user code
    # overrides prepare instead.
    def prepare_tree
      return if @prepared

      @prepared = true
      count = @children.length
      @children.each(&:prepare_tree)
      prepare
      # What the hook itself added, a resource most often.
      @children.drop(count).each(&:prepare_tree)
    end

    # Registers an L1 resource in the nearest Stack.
    #
    # opts are the properties, in snake_case. properties: carries exact
    # CloudFormation names instead, for the rare property called Metadata or
    # Condition, and cannot be combined with other keywords.
    #
    # Declared here because it is the tree's contract. The cfn component
    # implements it by reopening this class: core does not depend on cfn.
    def resource(id, type, properties: nil, depends_on: [], condition: nil, deletion_policy: nil, update_replace_policy: nil, metadata: {}, **opts)
      raise NotImplementedError, "added by the cfn component"
    end
  end
end
