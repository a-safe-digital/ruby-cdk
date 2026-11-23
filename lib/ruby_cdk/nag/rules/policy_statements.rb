# frozen_string_literal: true

require "json"
require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # Shared by the rules that read IAM policy statements: where a policy
      # document is written, how its statements are listed, and the tests a
      # statement is put to.
      #
      # Ported from cfn-model 0.6.6, the model cfn-nag reads templates with
      # (stelligent/cfn-model, commit 3ca846093639c1bfdf2069d33c8050ad66122e6b,
      # MIT, Copyright (c) 2016-2020 Stelligent):
      #   - lib/cfn-model/parser/policy_document_parser.rb, streamline_array:
      #     a Statement, an Action or a Resource is a list, or one item.
      #   - lib/cfn-model/model/principal.rb, Principal.wildcard?
      #
      # And from cdk-nag (cdklabs/cdk-nag, commit
      # da5bed77c1b08e584e3de2d67534c76871af957f, Apache-2.0),
      # src/rules/iam/IAMNoWildcardPermissions.ts and the two rules split from
      # it: which resources hold identity policies, namely the Policies of a
      # role, a user or a group, and the PolicyDocument of a policy resource.
      # Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
      # SPDX-License-Identifier: Apache-2.0
      #
      # What changed: written against a plain Hash instead of cfn-model's
      # objects, which resolve Refs through the model; here a Ref is dynamic
      # and the statement is left unevaluated. A document written as a JSON
      # string, which the schemas of KeyPolicy and PolicyDocument allow, is
      # parsed; cfn-model does not read one.
      module PolicyStatements
        STATEMENT = "Statement"
        INLINE_POLICIES = "Properties.Policies"
        INLINE_POLICY_TYPES = %w[AWS::IAM::Role AWS::IAM::User AWS::IAM::Group].freeze
        STANDALONE_DOCUMENT = "Properties.PolicyDocument"

        protected

        # Yields the path of every identity policy document on the resource:
        # the Policies that a role, a user or a group carries inline, or the
        # PolicyDocument of a policy resource. The trust policy of a role is
        # not among them: no cdk-nag rule reads one.
        def each_identity_policy_document
          unless INLINE_POLICY_TYPES.include?(type)
            yield STANDALONE_DOCUMENT
            return
          end

          policies = check(INLINE_POLICIES) { values.item_paths(INLINE_POLICIES) } || []
          policies.each { |policy| yield "#{policy}.PolicyDocument" }
        end

        # Yields the path and a Reader for every statement of the policy
        # document at path. A document that is dynamic, or that is not a
        # document, ends the listing with one Skipped record at path.
        def each_statement(document_path)
          statements = check(document_path) { statements_in(document_path) }
          statements&.each { |path, statement| yield path, statement }
        end

        # cfn-model's Principal.wildcard?: the principal is a String that holds
        # a "*", or an object one of whose String values, or String list items, does.
        def wildcard_principal?(principal)
          case principal
          when String
            principal.include?("*")
          when Hash
            principal.values.any? do |part|
              Array(part).any? { |item| item.is_a?(String) && item.include?("*") }
            end
          else
            false
          end
        end

        # True when the statement carries a Condition block with something in
        # it. Any condition counts as a restriction: reading which ones really
        # narrow the grant is beyond these rules.
        def restricts?(statement)
          condition = statement.raw("Condition")
          return false if condition.nil?
          return !condition.empty? if condition.is_a?(Hash) || condition.is_a?(Array)

          undecided(statement.full_path("Condition"), "is #{Values.preview(condition)}, not a condition block")
        end

        private

        # [[path, Reader], ...], one entry per statement of the document.
        def statements_in(document_path)
          v = values
          written = v.raw(document_path)
          document = case written
          when nil
            nil
          when Hash
            written
          when String
            parse_document(document_path, written)
          else
            raise Undecided.new(document_path, "is #{Values.preview(written)}, not a policy document")
          end
          return [] unless document

          root = v.sub(document_path, document)
          root.item_paths(STATEMENT).map do |path|
            [ root.full_path(path), root.at(path) ]
          end
        end

        # The provider schemas give KeyPolicy and PolicyDocument the types
        # ["object", "string"], so a document may be written as JSON text.
        def parse_document(path, text)
          JSON.parse(text)
        rescue JSON::ParserError
          raise Undecided.new(path, "is a string that is not JSON, so its statements cannot be read")
        end
      end
    end
  end
end
