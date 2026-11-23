# frozen_string_literal: true

require_relative "../tools/aws_isolation"

# The suite must run without any AWS credential in reach. `rake test` arranges
# that; a bare `ruby test/runner.rb` does not, and is refused.
unless Tools::AwsIsolation.scrubbed?
  abort "Run the suite with `bundle exec rake test`: it removes every AWS credential from the environment first."
end

require_relative "test_helper"

Dir[File.join(__dir__, "unit", "**", "*_test.rb")].sort.each { |path| require path }

# The CDK's own tests, ported (docs/07-testing.md): its assertions, its
# validation cases, its core. Each file says which cases it holds.
Dir[File.join(__dir__, "cdk", "**", "*_test.rb")].sort.each { |path| require path }

# What crosses components, in process: the umbrella, synthesis end to end, the
# examples against their committed templates. Against AWS is elsewhere: under
# test/integration/aws/, and only through `rake integration`.
Dir[File.join(__dir__, "integration", "in_process", "**", "*_test.rb")].sort.each { |path| require path }

# The component map is checked after the unit tests.
Dir[File.join(__dir__, "architecture", "*_test.rb")].sort.each { |path| require path }
