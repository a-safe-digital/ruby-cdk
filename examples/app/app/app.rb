# frozen_string_literal: true

# The code of the function: the file that the asset zips and Lambda runs.
#
# One handler, `app.handler`, that answers the same JSON whatever arrives, so
# there is no SDK, no gem and nothing to vendor here - this file is the whole
# deployment package. The role the stack gives the function may read and write
# the notes table and the assets bucket; this handler does not call them yet,
# so that the package stays dependency-free. Change a byte of this file and
# the next deploy carries a new asset: the hash of an asset is made of the
# bytes of its files.
def handler(event:, context:)
  { "statusCode" => 200, "body" => "notes app, from a ruby-cdk asset" }
end
