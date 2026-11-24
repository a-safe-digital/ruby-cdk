# frozen_string_literal: true

module RubyCdk
  module Validation
    # The parts of a template the rules read, and the walks they share. Nothing here
    # knows a rule: it is how a template says "Ref", where a value sits in it, and how
    # to visit every value.
    #
    # What an intrinsic looks like was read in the CDK, at commit
    # 68b2516c09791d78b199f30e455e4670dc9cde6d: packages/aws-cdk-lib/core/lib/private/
    # cloudformation-lang.ts, isIntrinsic, and helpers-internal/cfn-parse.ts,
    # looksLikeCfnIntrinsic. An object with the one key "Ref", or the one key "Fn::...":
    # an object with more keys is data, whatever its keys are called.
    module Template
      # The top-level sections a template is made of (architecture §5).
      SECTIONS = %w[AWSTemplateFormatVersion Description Parameters Mappings Conditions Resources Outputs Metadata].freeze

      # The sections whose values may hold no reference: CloudFormation takes literals there.
      LITERAL_SECTIONS = %w[AWSTemplateFormatVersion Description Parameters Mappings].freeze

      # The sections where a Ref reaches a parameter or a pseudo-parameter and nothing
      # else, as in the CDK (cfn-parse.ts: the finders of Conditions and of Rules answer
      # parameters alone).
      PARAMETERS_ONLY = %w[Conditions Rules].freeze

      module_function

      # An intrinsic as the template holds it: { "Ref" => "Name" } or { "Fn::..." => ... } and nothing else.
      def intrinsic?(value)
        return false unless value.is_a?(Hash) && value.size == 1

        key = value.keys.first
        key == "Ref" || (key.is_a?(String) && key.start_with?("Fn::"))
      end

      # True when value is the one intrinsic name: { name => ... }.
      def function?(value, name)
        value.is_a?(Hash) && value.size == 1 && value.key?(name)
      end

      # A String, a number, a boolean or nil: a value CloudFormation takes as it is written.
      def literal?(value)
        value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false || value.nil?
      end

      # "Resources.Table.Properties.KeySchema[0].KeyType": the way the pipeline writes a
      # path. A segment that starts with "[" is an index and follows the last name directly.
      def path(segments)
        segments.each_with_object(+"") do |segment, text|
          segment = segment.to_s
          next text << segment if segment.start_with?("[")

          text << "." unless text.empty?
          text << segment
        end
      end

      # Yields [ value, segments ] for value and everything below it, in the order it is
      # written.
      def walk(value, segments = [], &block)
        segments = Kernel.Array(segments)
        block.call(value, segments)
        case value
        when Hash
          value.each { |key, item| walk(item, segments + [ key.to_s ], &block) }
        when Array
          value.each_with_index { |item, index| walk(item, segments + [ "[#{index}]" ], &block) }
        end
        nil
      end

      # A section of the template, as a Hash: empty when the template does not have it
      # or holds something else there.
      def section(template, name)
        template.is_a?(Hash) && template[name].is_a?(Hash) ? template[name] : {}
      end

      # { "Table" => { "Type" => ... }, ... }: the resources of the template, those whose body is an object.
      def resources(template)
        section(template, "Resources").select { |_name, body| body.is_a?(Hash) }
      end

      # The Type of a resource, or nil when the body does not give it as a string.
      def resource_type(body)
        type = body["Type"] if body.is_a?(Hash)
        type.is_a?(String) ? type : nil
      end

      # The names that can be Ref'd or substituted: resources, parameters, and the
      # pseudo-parameters. The list of pseudo-parameters is the CDK's engine's
      # (aws-cloudformation/cloudformation-validate@55ff54b6, template-model/src/consts.rs,
      # PSEUDO_PARAMETERS).
      PSEUDO_PARAMETERS = %w[AWS::AccountId AWS::NotificationARNs AWS::NoValue AWS::Partition AWS::Region AWS::StackId AWS::StackName AWS::URLSuffix].freeze

      # The key the normalizer matches a property by: neither case nor underscores count
      # (architecture §6). "SSEAlgorithm" and "sse_algorithm" both give "ssealgorithm".
      def fold(name)
        name.downcase.delete("_")
      end

      # "KeySchema" as "key_schema", "KMSMasterKeyID" as "kms_master_key_id": the way a
      # property is written in Ruby.
      def snake(name)
        name.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      # The name of what a node describes, for a message: "AWS::DynamoDB::Table" for a
      # type, "AWS::DynamoDB::Table.KeySchema" for a definition nested in it.
      def node_name(type, node)
        node.equal?(type) ? type.name : "#{type.name}.#{node.name}"
      end

      # A value the way a message shows it: as Ruby writes it, and short.
      def show(value)
        text = value.inspect
        text.size > 60 ? "#{text[0, 57]}..." : text
      end

      def pseudo_parameter?(name)
        PSEUDO_PARAMETERS.include?(name)
      end

      # The logical ID and the attribute of an Fn::GetAtt, from its string form
      # "Id.Attribute" (the first dot separates them, the attribute may hold more) or its
      # list form [ "Id", "Attribute" ]. [ nil, nil ] when neither reads: a string with no
      # dot (rule V21 says so), or anything that is not two names.
      def get_att(argument)
        if argument.is_a?(String)
          dot = argument.index(".")
          dot ? [ argument[0, dot], argument[(dot + 1)..] ] : [ nil, nil ]
        elsif argument.is_a?(Array) && argument.size == 2 && argument[0].is_a?(String) && argument[1].is_a?(String)
          argument
        else
          [ nil, nil ]
        end
      end

      # Yields each variable of the string of an Fn::Sub the way CloudFormation reads it:
      # from "${" to the next "}", trimmed. "${!...}" is no variable but literal text.
      # Read in the CDK (cfn-parse.ts, parseFnSubString, aws/aws-cdk@68b2516c), with its
      # test fixtures: a "${" with no "}" after it is text too.
      def variables(string)
        position = string.index("${") || string.length
        while (opening = string.index("${", position))
          closing = string.index("}", opening + 2)
          break unless closing

          name = string[(opening + 2)...closing].strip
          position = closing + 1
          yield name unless name.start_with?("!")
        end
      end

      # Whether an attribute is one a resource type returns from Fn::GetAtt. A read-only
      # path covers what lies below it ("Outputs" covers "Outputs.Key", "Endpoint" covers
      # "Endpoint.Address"), and a "*" in it is any one segment, as the schemas write them.
      def attribute?(read_only, attribute)
        read_only.any? do |known|
          next true if known == attribute || attribute.start_with?("#{known}.")

          pattern = known.split(".").map { |part| part == "*" ? "[^.]+" : Regexp.escape(part) }.join("\\.")
          attribute.match?(/\A#{pattern}\z/)
        end
      end

      # The names of a template that a reference can reach.
      class Names
        attr_reader :resources, :parameters, :conditions, :mappings

        # resources and parameters: the logical IDs. conditions and mappings: their names.
        def initialize(template)
          @bodies = Template.resources(template)
          @resources = @bodies.keys.map(&:to_s)
          @parameters = Template.section(template, "Parameters").keys.map(&:to_s)
          @conditions = Template.section(template, "Conditions").keys.map(&:to_s)
          @mappings = Template.section(template, "Mappings").keys.map(&:to_s)
          freeze
        end

        def resource?(name)
          @resources.include?(name)
        end

        def parameter?(name)
          @parameters.include?(name)
        end

        def condition?(name)
          @conditions.include?(name)
        end

        def mapping?(name)
          @mappings.include?(name)
        end

        # The body of a resource, or nil.
        def body(name)
          @bodies[name]
        end
      end
    end
  end
end
