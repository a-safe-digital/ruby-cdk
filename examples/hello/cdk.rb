# frozen_string_literal: true

# The hello app: one stack, `hello`, with one S3 bucket that stays private.
#
# The app file. It requires the gem and creates exactly one RubyCdk::App; the
# stack is a class of its own, so that it can be built here and somewhere else,
# under another name.
#
# Run it with the command line, from this directory (see README.md):
#
#   ruby-cdk synth
#   ruby-cdk deploy
#   ruby-cdk destroy
require "ruby-cdk"
require_relative "hello/stack"

RubyCdk::App.new do |app|
  Hello::Stack.new(app, "hello")
end
