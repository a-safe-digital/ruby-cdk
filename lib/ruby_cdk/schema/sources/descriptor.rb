# frozen_string_literal: true

module RubyCdk
  module Schema
    module Sources
      # One property, list element or map value as the compilers describe it, before it is
      # written into the model.
      #
      #   kind     one of the ten kinds
      #   item     for :list and :map, the kind of each element; nil for the other kinds
      #   of       the definition that describes a :nested value, or a :nested element of a list or map
      #   values   the literals the source allows, or nil when it lists none or leaves the choice open
      #   pattern  the one pattern the source states, or nil when it states none or several
      #   unique   for :list: whether duplicates are allowed, or nil when no source says
      Descriptor = Data.define(:kind, :item, :of, :values, :pattern, :unique)

      # Anything at all: a value no source describes closely.
      ANY_VALUE = Descriptor.new(kind: :json, item: nil, of: nil, values: nil, pattern: nil, unique: nil).freeze
    end
  end
end
