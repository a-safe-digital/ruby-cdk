# frozen_string_literal: true

# The lambda app: one stack, `lambda`, with one function whose code is a zipped
# directory of files, the role that runs it and the log group its logs land in.
#
# The app file. It requires the gem and creates exactly one RubyCdk::App; the
# stack is a class of its own, so that it can be built here and somewhere else,
# under another name.
#
# The env is pinned because an asset needs a concrete one: the name of the
# bucket its zip is uploaded to is made of the account and the region, and
# synthesis never calls AWS to discover them. Replace the account and the
# region with your own before deploying — a stack with an env deploys only
# into that account and region.
#
# Run it with the command line, from this directory (see README.md):
#
#   ruby-cdk synth
#   ruby-cdk deploy
#   ruby-cdk destroy
require "ruby-cdk"
require_relative "lambda/stack"

RubyCdk::App.new(env: RubyCdk::Env.new(account: "111122223333", region: "eu-central-1")) do |app|
  Lambda::Stack.new(app, "lambda")
end
