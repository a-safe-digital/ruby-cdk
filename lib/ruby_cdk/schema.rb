# frozen_string_literal: true

require_relative "schema/property_schema"
require_relative "schema/type_schema"
require_relative "schema/schema"

module RubyCdk
  # What AWS resources look like: one small model vendored from the two sources AWS
  # publishes, the provider schemas and the resource specification. The rules and the
  # diff talk to the model, never to a source.
  #
  #   RubyCdk::Schema.type("AWS::Lambda::Function")       # a TypeSchema, or nil for an unknown type
  #   RubyCdk::Schema.update_type(type, "Code.S3Bucket")  # :immutable
  #
  # The model is parsed on the first lookup. `rake spec:update` rebuilds it, from
  # lib/ruby_cdk/schema/sources, which nothing else loads.
  module Schema
  end
end
