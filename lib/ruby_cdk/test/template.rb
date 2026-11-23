# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/assertions/lib/template.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: camelCase to snake_case. fromStack(stack), which synthesizes the
#   stage the stack belongs to, is template(source): anything with a to_template
#   method, asked by duck typing, or a Hash, or a JSON string. This tool has no
#   Stage, App or NestedStack, so the nested-stack branch of toTemplate() has no
#   counterpart. TemplateParsingOptions is a second argument, an options Hash
#   (with a keyword parameter of its own, `from_json("Resources" => { ... })`
#   could not be written). A template that is not a JSON object is an
#   ArgumentError here, where the CDK accepts it and fails later. The Symbols of a
#   Hash become strings (Js.normalize).
#
#   Not in the CDK, added here: get(path), because a Ruby test has no jest
#   snapshot to compare a template with; and the second half of to_json, which
#   answers Ruby's JSON library with text when it is the caller.

require_relative "capture"
require_relative "match"
require_relative "matcher"
require_relative "private/conditions"
require_relative "private/cyclic"
require_relative "private/error"
require_relative "private/js"
require_relative "private/mappings"
require_relative "private/outputs"
require_relative "private/parameters"
require_relative "private/resources"

module RubyCdk
  module Test
    # Suite of assertions that can be run on a CDK stack.
    # Typically used, as part of unit tests, to validate that the rendered
    # CloudFormation template has expected resources and properties.
    #
    # Build one with RubyCdk::Test.template, from_string or from_json. Every
    # method that asserts raises RubyCdk::Test::AssertionError when it fails.
    #
    # The three ways of building one take their options as a second argument, the
    # CDK's TemplateParsingOptions, and not as keywords of their own: with a
    # keyword parameter, Ruby would read `from_json("Resources" => { ... })`, a
    # Hash written without braces, as keywords and find no template. So both of
    # these give the same Template:
    #
    #   RubyCdk::Test.from_json(template, skip_cyclical_dependencies_check: true)
    #   RubyCdk::Test.from_json(template, { skip_cyclical_dependencies_check: true })
    class Template
      # Base your assertions on the CloudFormation template of a stack.
      #
      # In the CDK: Template.fromStack(stack). source is anything with a
      # `to_template` method, a Hash, or a template as a JSON string.
      #
      # options: :skip_cyclical_dependencies_check, true to skip checking for
      # cyclical / circular dependencies. Leave it out other than for templates
      # that are valid despite containing cycles, such as unprocessed transform
      # stacks.
      def self.template(source, options = {})
        if source.respond_to?(:to_template)
          json = source.to_template
        elsif source.is_a?(String)
          json = JSON.parse(source, max_nesting: false)
        elsif source.is_a?(Hash)
          json = source
        else
          raise ArgumentError,
            "Expected a template: anything with a to_template method, a Hash or a JSON string, got #{source.class}"
        end
        new(json, options[:skip_cyclical_dependencies_check])
      end

      # Base your assertions from an existing CloudFormation template formatted as a
      # JSON string.
      #
      # options: as in template.
      def self.from_string(template, options = {})
        new(JSON.parse(template, max_nesting: false), options[:skip_cyclical_dependencies_check])
      end

      # Base your assertions from an existing CloudFormation template formatted as
      # an in-memory JSON object.
      #
      # options: as in template.
      def self.from_json(template, options = {})
        new(template, options[:skip_cyclical_dependencies_check])
      end

      def initialize(template, skip_cyclical_dependencies_check)
        unless template.is_a?(Hash)
          raise ArgumentError, "A CloudFormation template is a JSON object, got #{Private.get_type(template)}"
        end

        @template = Private::Js.normalize(template)
        Private.check_template_for_cyclic_dependencies(@template) unless skip_cyclical_dependencies_check
      end
      private_class_method :new

      # The CloudFormation template deserialized into an object: a Hash.
      #
      # This is the CDK's toJSON(). Ruby's JSON library also calls `to_json` on
      # whatever it is asked to serialize, passing its state object and expecting
      # text back; when a state is given, the template answers with its JSON text.
      def to_json(state = nil, *)
        state ? @template.to_json(state) : @template
      end

      # Assert that the given number of resources of the given type exist in the
      # template.
      #
      # type:  the resource type; ex: `AWS::S3::Bucket`
      # count: number of expected instances
      def resource_count_is(type, count)
        counted = Private.count_resources(@template, type)
        if counted != count
          raise AssertionError, "Expected #{count} resources of type #{type} but found #{counted}"
        end
        nil
      end

      # Assert that the given number of resources of the given type and properties
      # exists in the CloudFormation template.
      #
      # type:  the resource type; ex: `AWS::S3::Bucket`
      # props: the 'Properties' section of the resource as should be expected in the template
      # count: number of expected instances
      def resource_properties_count_is(type, props, count)
        counted = Private.count_resources_properties(@template, type, props)
        if counted != count
          raise AssertionError, "Expected #{count} resources of type #{type} but found #{counted}"
        end
        nil
      end

      # Assert that a resource of the given type and properties exists in the
      # CloudFormation template.
      # By default, performs partial matching on the `Properties` key of the resource,
      # via the `Match.object_like()`. To configure different behavior, use other
      # matchers in the `Match` class.
      #
      # type:  the resource type; ex: `AWS::S3::Bucket`
      # props: the 'Properties' section of the resource as should be expected in the template
      def has_resource_properties(type, props)
        match_error = Private.has_resource_properties(@template, type, props)
        raise AssertionError, match_error if match_error

        nil
      end

      # Assert that a resource of the given type and given definition exists in the
      # CloudFormation template.
      # By default, performs partial matching on the resource, via the `Match.object_like()`.
      # To configure different behavior, use other matchers in the `Match` class.
      #
      # type:  the resource type; ex: `AWS::S3::Bucket`
      # props: the entire definition of the resource as should be expected in the template
      def has_resource(type, props)
        match_error = Private.has_resource(@template, type, props)
        raise AssertionError, match_error if match_error

        nil
      end

      # Get the set of matching resources of a given type and properties in the
      # CloudFormation template.
      #
      # type:  the type to match in the CloudFormation template
      # props: by default, matches all resources with the given type.
      #        When a literal is provided, performs a partial match via `Match.object_like()`.
      #        Use the `Match` APIs to configure a different behaviour.
      def find_resources(type, props = {})
        Private.find_resources(@template, type, props)
      end

      # Get the Resource ID of a matching resource, expects only to find one match.
      # Throws AssertionError if none or multiple resources were found.
      #
      # type:  the resource type; ex: `AWS::S3::Bucket`
      # props: by default, matches all resources with the given type.
      #        Performs a partial match via `Match.object_like()`.
      #
      # Returns the resource id of the matched resource.
      def get_resource_id(type, props = {})
        resource_id, match_error = Private.get_resource_id(@template, type, props)

        raise AssertionError, match_error if match_error
        raise AssertionError, "unexpected: resourceId was undefined" unless resource_id

        resource_id
      end

      # Assert that all resources of the given type contain the given definition in
      # the CloudFormation template.
      # By default, performs partial matching on the resource, via the `Match.object_like()`.
      # To configure different behavior, use other matchers in the `Match` class.
      #
      # type:  the resource type; ex: `AWS::S3::Bucket`
      # props: the entire definition of the resources as they should be expected in the template
      def all_resources(type, props)
        match_error = Private.all_resources(@template, type, props)
        raise AssertionError, match_error if match_error

        nil
      end

      # Assert that all resources of the given type contain the given properties
      # CloudFormation template.
      # By default, performs partial matching on the `Properties` key of the
      # resource, via the `Match.object_like()`. To configure different behavior, use
      # other matchers in the `Match` class.
      #
      # type:  the resource type; ex: `AWS::S3::Bucket`
      # props: the 'Properties' section of the resource as should be expected in the template
      def all_resources_properties(type, props)
        match_error = Private.all_resources_properties(@template, type, props)
        raise AssertionError, match_error if match_error

        nil
      end

      # Assert that a Parameter with the given properties exists in the CloudFormation template.
      # By default, performs partial matching on the parameter, via the `Match.object_like()`.
      # To configure different behavior, use other matchers in the `Match` class.
      #
      # logical_id: the name of the parameter, provide `'*'` to match all parameters in the template
      # props:      the parameter as should be expected in the template
      def has_parameter(logical_id, props)
        match_error = Private.has_parameter(@template, logical_id, props)
        raise AssertionError, match_error if match_error

        nil
      end

      # Get the set of matching Parameters that match the given properties in the
      # CloudFormation template.
      #
      # logical_id: the name of the parameter, provide `'*'` to match all parameters in the template
      # props:      by default, matches all Parameters in the template. When a literal
      #             object is provided, performs a partial match via `Match.object_like()`.
      #             Use the `Match` APIs to configure a different behaviour.
      def find_parameters(logical_id, props = {})
        Private.find_parameters(@template, logical_id, props)
      end

      # Assert that an Output with the given properties exists in the CloudFormation template.
      # By default, performs partial matching on the resource, via the `Match.object_like()`.
      # To configure different behavior, use other matchers in the `Match` class.
      #
      # logical_id: the name of the output, provide `'*'` to match all outputs in the template
      # props:      the output as should be expected in the template
      def has_output(logical_id, props)
        match_error = Private.has_output(@template, logical_id, props)
        raise AssertionError, match_error if match_error

        nil
      end

      # Get the set of matching Outputs that match the given properties in the
      # CloudFormation template.
      #
      # logical_id: the name of the output, provide `'*'` to match all outputs in the template
      # props:      by default, matches all Outputs in the template. When a literal
      #             object is provided, performs a partial match via `Match.object_like()`.
      #             Use the `Match` APIs to configure a different behaviour.
      def find_outputs(logical_id, props = {})
        Private.find_outputs(@template, logical_id, props)
      end

      # Assert that a Mapping with the given properties exists in the CloudFormation template.
      # By default, performs partial matching on the resource, via the `Match.object_like()`.
      # To configure different behavior, use other matchers in the `Match` class.
      #
      # logical_id: the name of the mapping, provide `'*'` to match all mappings in the template
      # props:      the mapping as should be expected in the template
      def has_mapping(logical_id, props)
        match_error = Private.has_mapping(@template, logical_id, props)
        raise AssertionError, match_error if match_error

        nil
      end

      # Get the set of matching Mappings that match the given properties in the
      # CloudFormation template.
      #
      # logical_id: the name of the mapping, provide `'*'` to match all mappings in the template
      # props:      by default, matches all Mappings in the template. When a literal
      #             object is provided, performs a partial match via `Match.object_like()`.
      #             Use the `Match` APIs to configure a different behaviour.
      def find_mappings(logical_id, props = {})
        Private.find_mappings(@template, logical_id, props)
      end

      # Assert that a Condition with the given properties exists in the CloudFormation template.
      # By default, performs partial matching on the resource, via the `Match.object_like()`.
      # To configure different behavior, use other matchers in the `Match` class.
      #
      # logical_id: the name of the condition, provide `'*'` to match all conditions in the template
      # props:      the condition as should be expected in the template
      def has_condition(logical_id, props)
        match_error = Private.has_condition(@template, logical_id, props)
        raise AssertionError, match_error if match_error

        nil
      end

      # Get the set of matching Conditions that match the given properties in the
      # CloudFormation template.
      #
      # logical_id: the name of the condition, provide `'*'` to match all conditions in the template
      # props:      by default, matches all Conditions in the template. When a literal
      #             object is provided, performs a partial match via `Match.object_like()`.
      #             Use the `Match` APIs to configure a different behaviour.
      def find_conditions(logical_id, props = {})
        Private.find_conditions(@template, logical_id, props)
      end

      # Assert that the CloudFormation template matches the given value.
      #
      # expected: the expected CloudFormation template as key-value pairs. A
      #           partial match through `Match.object_like()`, unless it is a Matcher.
      def template_matches(expected)
        matcher = Matcher.matcher?(expected) ? expected : Match.object_like(expected)
        result = matcher.test(@template)

        if result.has_failed?
          raise AssertionError,
            [ "Template did not match as expected. The following mismatches were found:", *result.to_human_strings.map { |string| "\t#{string}" } ].join("\n")
        end
        nil
      end

      # The value at a path of the template, as a Capture: the `as_*` methods of
      # the capture give it back with its type checked.
      #
      #   template.get("Resources.Fn.Properties.Timeout").as_number
      #   template.get([ "Resources", "Role", "Properties", "ManagedPolicyArns", 0 ]).as_string
      #
      # path: the keys from the root, separated by dots, or a list of keys and
      #       array indexes.
      #
      # Raises RubyCdk::Test::AssertionError when the template has no value there.
      #
      # Not in the CDK; added here because a Ruby test has no jest snapshot.
      def get(path)
        segments = path.is_a?(String) ? path.split(".") : path.map(&:to_s)
        value = @template
        segments.each do |segment|
          found =
            if value.is_a?(Array) && segment.match?(/\A\d+\z/)
              segment.to_i < value.length ? value[segment.to_i] : nil
            elsif value.is_a?(Hash) && value.key?(segment)
              value[segment]
            end
          if found.nil?
            raise AssertionError, "Template has no value at #{segments.join(".")}"
          end

          value = found
        end

        capture = Capture.new
        capture.test(value).finished
        capture
      end
    end
  end
end
