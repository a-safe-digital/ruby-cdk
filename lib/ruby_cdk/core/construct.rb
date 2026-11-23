# frozen_string_literal: true

require_relative "../fn"

module RubyCdk
  # Any node in the tree. Building is immediate: a construct exists as soon as
  # its constructor returns.
  class Construct
    # So that `Fn.ref` resolves inside any construct or Stack subclass.
    Fn = RubyCdk::Fn

    # Letters, digits, underscore and hyphen. Logical IDs are narrower: alphanumeric only.
    ID_PATTERN = /\A[A-Za-z0-9_-]+\z/

    attr_reader :scope, :id, :path

    # scope is an App, a Stack or another Construct.
    def initialize(scope, id)
      raise NotImplementedError, "Wave 1, track A"
    end

    def children
      raise NotImplementedError, "Wave 1, track A"
    end

    # Validates the id and rejects duplicates among siblings. Returns node.
    def add(node)
      raise NotImplementedError, "Wave 1, track A"
    end

    # Hook, children first. Curated constructs add implicit resources here.
    def prepare; end

    # Registers an L1 resource in the nearest Stack.
    #
    # opts are the properties, in snake_case. properties: carries exact
    # CloudFormation names instead, for the rare property called Metadata or
    # Condition, and cannot be combined with other keywords.
    def resource(id, type, properties: nil, depends_on: [], condition: nil, deletion_policy: nil, update_replace_policy: nil, metadata: {}, **opts)
      raise NotImplementedError, "Wave 1, track A"
    end

    # The nearest enclosing Stack.
    def stack
      raise NotImplementedError, "Wave 1, track A"
    end
  end
end
