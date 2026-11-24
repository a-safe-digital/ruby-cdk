# frozen_string_literal: true

require_relative "../lib/ruby_cdk/schema/sources"

desc "Rebuild the vendored schema model under data/spec from the two sources AWS publishes. " \
     "Network. REGION picks the region, us-east-1 by default. Writes only when the model changed, " \
     "and fails when a source is gone (HTTP 404) or has not changed for 90 days (decision D-005)"
task "spec:update" do
  result = RubyCdk::Schema::Sources.update(region: ENV.fetch("REGION", "us-east-1"), dir: File.expand_path("../data/spec", __dir__))
  puts result.summary
rescue RubyCdk::Error => error
  abort "spec: #{error.message}"
end
