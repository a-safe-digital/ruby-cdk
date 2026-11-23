# frozen_string_literal: true

# What tapioca loads before it writes the RBI files for the runtime gems.
# Regenerate them with `rake rbi:update`.
require "aws-sdk-cloudformation"
require "aws-sdk-s3"
require "thor"
require "zip"
