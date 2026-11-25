# frozen_string_literal: true

# The code of the function: the file that the asset zips and Lambda runs.
#
# One handler, `app.handler`, that answers the same hash whatever arrives, so
# there is no SDK, no gem and nothing to vendor here — this file is the whole
# deployment package. Change a byte of it and the next deploy carries a new
# asset: the hash of an asset is made of the bytes of its files (see
# README.md).
def handler(event:, context:)
  { "statusCode" => 200, "body" => "hello from a ruby-cdk asset" }
end
