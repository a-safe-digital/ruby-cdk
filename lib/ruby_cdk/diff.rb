# frozen_string_literal: true

require_relative "errors"
require_relative "deploy/ports"
require_relative "schema"
require_relative "diff/normalizer"
require_relative "diff/compare"
require_relative "diff/statement"
require_relative "diff/security"
require_relative "diff/template"
require_relative "diff/render"

module RubyCdk
  # The change preview of two templates (architecture section 10): what would
  # change between the template that is deployed and the one that was
  # synthesized, per resource with what replaces it, and the security view in
  # a table of its own. `ruby-cdk diff` renders it; this module computes it.
  module Diff
    # The diff of two templates. Either side may be nil -- a stack that does
    # not exist yet diffs against nothing, and everything is an Add -- a Hash,
    # or the text of a template (JSON, or YAML when another tool deployed it
    # in that form). Templates are normalized on copies; the caller's objects
    # are never touched. stack_name is carried onto the diff for the renderer
    # and the JSON.
    def self.of(old_template, new_template, stack_name: nil)
      TemplateDiff.build(normal_side(old_template), normal_side(new_template), stack_name:)
    end

    # The diff of one stack: the template it deploys against the template the
    # deployed stack answers with, read through the port's `get_template`
    # (module RubyCdk::Deploy::CfnClient) and no other call. A client that
    # answers nil -- the stack does not exist, or was deleted -- diffs against
    # nothing.
    def self.for_stack(client, name, template:, stack_name: nil)
      deployed = client.get_template(name)
      old_template = deployed.nil? ? {} : deployed_template(deployed, name)
      of(old_template, template, stack_name: stack_name || name)
    end

    # The text of a diff, for a person (Render.call).
    def self.render(diff, quiet: false, security_only: false)
      Render.call(diff, quiet: quiet, security_only: security_only)
    end

    def self.normal_side(template)
      return nil if template.nil?

      body = template.is_a?(String) ? Normalizer.parse(template) : template
      raise Error, "a template is a JSON object, not #{body.class}, so it cannot be diffed" unless body.is_a?(Hash)

      Normalizer.normalize(body)
    end
    private_class_method :normal_side

    def self.deployed_template(text, name)
      Normalizer.parse(text)
    rescue Error => e
      raise Error, "The deployed template of stack #{name} cannot be read: #{e.message}"
    end
    private_class_method :deployed_template
  end
end
