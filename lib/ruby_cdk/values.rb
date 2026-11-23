# frozen_string_literal: true

# The values a template is made of: CloudFormation functions, the deferred value
# and a concrete target. Loads alone: depends only on the errors.
require_relative "errors"
require_relative "fn"
require_relative "lazy"
require_relative "env"
