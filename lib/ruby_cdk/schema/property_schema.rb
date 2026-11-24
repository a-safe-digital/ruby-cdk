# frozen_string_literal: true

module RubyCdk
  module Schema
    # One property of a resource type or of a nested property type. A value object:
    # frozen, and equal to another with the same members.
    #
    #   name              the CloudFormation name, "KmsKeyId"
    #   kind              :string, :integer, :long, :double, :boolean, :timestamp, :json, :list, :map or :nested
    #   item_kind         for :list and :map, the kind of each element; nil for the other kinds
    #   definition        the key of TypeSchema#definitions that describes the value. Set when kind
    #                     is :nested, and when item_kind is :nested (then it describes each element)
    #   required          true when the enclosing type lists the property as required
    #   update_behaviour  :mutable, :immutable, :conditional, or :unknown when no source states it
    #   allowed_values    the literals the source allows, or nil when it lists none or leaves the choice open
    #   pattern           what a literal string must match, or nil when the source has no single pattern
    #   unique_items      for :list: whether duplicates are allowed, or nil when no source says
    #
    # For a :list or a :map, allowed_values and pattern apply to each element.
    PropertySchema = Data.define(:name, :kind, :item_kind, :definition, :required, :update_behaviour, :allowed_values, :pattern, :unique_items)
  end
end
