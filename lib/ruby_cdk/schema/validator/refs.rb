# frozen_string_literal: true

require_relative "../../schema"
require_relative "rule"
require_relative "template"

module RubyCdk
  module Validation
    # The rules over what a template refers to: its references, its substitutions, its
    # conditions, and the shapes CloudFormation takes only in some places (architecture
    # §6: V8 to V11, V14, V20, V21 and V22).
    #
    # Every rule here has one in the CDK: the checks its include makes when it reads a
    # template (packages/aws-cdk-lib/core/lib/helpers-internal/cfn-parse.ts and
    # cloudformation-include/lib/cfn-include.ts, aws/aws-cdk@68b2516c), or the ones its
    # engine makes (aws-cloudformation/cloudformation-validate@55ff54b6,
    # src/cel-engine/src/rules/intrinsics.rs). Each rule says which, and follows it.
    module Rules
      # The places of a template where a reference can be written: every value of every
      # section but Parameters and Mappings, which take literals. A template nested in a
      # resource (the TemplateBody of an AWS::CloudFormation::Stack) is another template,
      # with names of its own, and is left alone.
      module Sites
        NESTED_STACK = "AWS::CloudFormation::Stack"

        module_function

        # Yields [ value, segments, parameters_only ] for every value, in the order it is
        # written. parameters_only is true in Conditions and in Rules, where a Ref reaches
        # a parameter or a pseudo-parameter and nothing else. Answers an Enumerator
        # without a block.
        def each(context)
          template = context.template
          return unless template.is_a?(Hash)

          template.each do |section, content|
            next if Template::LITERAL_SECTIONS.include?(section)

            parameters_only = Template::PARAMETERS_ONLY.include?(section)
            if section == "Resources"
              Template.resources(template).each do |name, body|
                yield_resource(body, [ "Resources", name.to_s ], body["Type"] == NESTED_STACK) { |value, at| yield value, at, parameters_only }
              end
            else
              Template.walk(content, section.to_s) { |value, at| yield value, at, parameters_only }
            end
          end
        end

        def yield_resource(body, at, nested)
          body.each do |attribute, value|
            if nested && attribute == "Properties" && value.is_a?(Hash)
              value.each do |key, item|
                next if key == "TemplateBody"

                Template.walk(item, at + [ "Properties", key.to_s ]) { |found, path| yield found, path }
              end
            else
              Template.walk(value, at + [ attribute.to_s ]) { |found, path| yield found, path }
            end
          end
        end
      end

      # V8: a Ref names a resource, a parameter or a pseudo-parameter of the stack; in
      # Conditions and in Rules, a parameter or a pseudo-parameter.
      #
      # The CDK: "Element used in Ref expression with logical ID: 'DoesNotExist' not
      # found" (cfn-parse.ts), where its finder answers resources and parameters and
      # specialCaseRefs lists the pseudo-parameters; in Conditions the finder answers
      # parameters alone. The engine: F1010, and F1020 for the target of a GetAtt.
      class References < Rule
        rule "V8"

        def call(context)
          names = Template::Names.new(context.template)
          issues = []
          Sites.each(context) do |value, at, parameters_only|
            next unless Template.function?(value, "Ref")

            target = value["Ref"]
            next unless target.is_a?(String)
            next if Template.pseudo_parameter?(target) || names.parameter?(target) || (!parameters_only && names.resource?(target))

            issues << error(at, "Ref names #{target.inspect}, which is not #{reachable(parameters_only)} of this stack",
              hint: parameters_only ? "a condition reaches parameters and pseudo-parameters only, by Ref" : "check the logical ID, or declare it")
          end
          issues
        end

        private

        def reachable(parameters_only)
          parameters_only ? "a parameter or a pseudo-parameter" : "a resource, a parameter or a pseudo-parameter"
        end
      end

      # V9: the attribute of an Fn::GetAtt is one the type returns. The model is silent
      # where its sources are: a type with no attribute listed is not checked, nor are the
      # types whose attributes are open (the nested stack returns Outputs.<name>), nor a
      # custom resource, whose attributes its own function decides. Those are the
      # exemptions of the CDK's engine (intrinsics.rs, E9004 and getatt_attr_is_map_member).
      #
      # KNOWN_ATTRIBUTES holds what the corpus proves the model short of: Version, which
      # CloudFormation returns for the two ImageBuilder recipes and the schemas do not
      # list (two templates of the sample read it and deployed). The CDK's engine keeps
      # the same kind of list, handwritten, where its data falls short
      # (aws-cloudformation/cloudformation-validate@55ff54b6,
      # src/data-source/handwritten/getatt_return_type_overrides.json).
      #
      # A resource the GetAtt names that is not there is rule V8's, as in the CDK: "Resource
      # used in GetAtt expression with logical ID: 'DoesNotExist' not found".
      class Attributes < Rule
        rule "V9"

        OPEN = %w[AWS::CloudFormation::Stack AWS::CloudFormation::Macro].freeze
        KNOWN_ATTRIBUTES = {
          "AWS::ImageBuilder::ContainerRecipe" => %w[Version],
          "AWS::ImageBuilder::ImageRecipe" => %w[Version]
        }.freeze
        LISTED = 12

        def call(context)
          names = Template::Names.new(context.template)
          issues = []
          Sites.each(context) do |value, at, _parameters_only|
            next unless Template.function?(value, "Fn::GetAtt")

            target, attribute = Template.get_att(value["Fn::GetAtt"])
            next unless target && attribute

            unless names.resource?(target)
              issues << error(at, "Fn::GetAtt names #{target.inspect}, which is not a resource of this stack",
                hint: names.parameter?(target) ? "an attribute is read from a resource; a parameter is Ref'd" : "check the logical ID")
              next
            end
            type = Template.resource_type(names.body(target))
            next if type.nil? || custom?(type) || OPEN.include?(type)

            schema = Schema.type(type)
            next unless schema && !schema.read_only.empty?
            next if Template.attribute?(schema.read_only, attribute)
            next if KNOWN_ATTRIBUTES.fetch(type, []).include?(attribute)

            issues << error(at, "#{attribute.inspect} is not an attribute AWS returns for #{type}; the attributes are #{listed(schema.read_only)}",
              hint: schema.documentation_url ? "see #{schema.documentation_url}" : "check the attribute's name")
          end
          issues
        end

        private

        def custom?(type)
          type == "AWS::CloudFormation::CustomResource" || type.start_with?("Custom::")
        end

        def listed(attributes)
          Text.list(attributes.first(LISTED)) + (attributes.size > LISTED ? ", and more" : "")
        end
      end

      # V10: a variable of an Fn::Sub names a logical ID or has a value supplied in the
      # Fn::Sub's own map. "${Id.Attribute}" reads an attribute of the resource Id.
      #
      # The CDK (cfn-parse.ts, parseFnSubString): the map is looked at first, then a
      # pseudo-parameter, then, for a name with a dot, a resource, and without one a
      # parameter or a resource: "Element referenced in Fn::Sub expression with logical
      # ID: 'AFakeResource' was not found in the template". The engine: F1018.
      class Substitutions < Rule
        rule "V10"

        def call(context)
          names = Template::Names.new(context.template)
          issues = []
          Sites.each(context) do |value, at, _parameters_only|
            next unless Template.function?(value, "Fn::Sub")

            string, supplied = parts(value["Fn::Sub"])
            next unless string

            Template.variables(string) do |name|
              next if name.empty? || supplied.key?(name) || reachable?(names, name)

              issues << error(at, "#{name.inspect} in the Fn::Sub names no resource, parameter or pseudo-parameter of this stack, " \
                                   "and the Fn::Sub supplies no value for it",
                hint: "add it to the map of the Fn::Sub, as Fn.sub(string, #{name.inspect} => value)")
            end
          end
          issues
        end

        private

        # [ the string, the supplied values by name ] of an Fn::Sub, or [ nil, nil ] for
        # one of another shape, which no rule here is about.
        def parts(argument)
          return [ argument, {} ] if argument.is_a?(String)
          return [ argument[0], argument[1] ] if argument.is_a?(Array) && argument.size == 2 && argument[0].is_a?(String) && argument[1].is_a?(Hash)

          [ nil, nil ]
        end

        def reachable?(names, name)
          dot = name.index(".")
          target = dot ? name[0, dot] : name
          return true if Template.pseudo_parameter?(target) || names.parameter?(target) || names.resource?(target)

          !dot && name.include?("::")
        end
      end

      # V11: what DependsOn and Condition name exists. DependsOn names resources; the
      # Condition of a resource and of an output, the condition of an Fn::If and of a
      # "Condition" inside Conditions, and the mapping of an Fn::FindInMap, exist.
      #
      # The CDK (cfn-parse.ts): "Resource 'Bucket2' depends on 'Bucket1' that doesn't
      # exist", "Resource 'Bucket' uses Condition 'AlwaysFalseCond' that doesn't exist",
      # "Condition 'AlwaysFalse' used in an Fn::If expression does not exist in the
      # template", "Referenced Condition with name 'AlwaysFalse' was not found in the
      # template", "Mapping used in FindInMap expression with name 'NonExistentMapping' was
      # not found in the template"; and cfn-include.ts for an output: "Output with name
      # 'SomeOutput' refers to a Condition with name 'NonexistentCondition' which was not
      # found in this template". The engine: E3005, E8002, E6005, E1028, E8007 and F1012.
      class Targets < Rule
        rule "V11"

        def call(context)
          names = Template::Names.new(context.template)
          issues = depends_on(context.template, names)
          issues.concat(condition_of_resources(context.template, names))
          issues.concat(condition_of_outputs(context.template, names))
          Sites.each(context) do |value, at, _parameters_only|
            issues << inside(value, at, names)
          end
          issues.compact
        end

        private

        def depends_on(template, names)
          Template.resources(template).flat_map do |name, body|
            next [] unless body.key?("DependsOn")

            declared = body["DependsOn"]
            list = declared.is_a?(Array) ? declared : [ declared ]
            list.each_with_index.filter_map do |target, index|
              at = [ "Resources", name.to_s, "DependsOn", *(declared.is_a?(Array) ? [ "[#{index}]" ] : []) ]
              if !target.is_a?(String)
                error(at, "DependsOn names #{Template.show(target)}: it takes the logical ID of a resource, or a list of them",
                  hint: "write the logical ID, as depends_on: \"Name\" or depends_on: [ \"A\", \"B\" ]")
              elsif !names.resource?(target)
                error(at, "the resource #{name} depends on #{target.inspect}, which is not a resource of this stack",
                  hint: names.parameter?(target) ? "DependsOn reaches resources only; a parameter needs no dependency" : "check the logical ID")
              end
            end
          end
        end

        def condition_of_resources(template, names)
          Template.resources(template).filter_map do |name, body|
            next unless body.key?("Condition")

            no_condition([ "Resources", name.to_s, "Condition" ], names, body["Condition"], "used by the resource #{name}")
          end
        end

        def condition_of_outputs(template, names)
          Template.section(template, "Outputs").filter_map do |name, output|
            next unless output.is_a?(Hash) && output.key?("Condition")

            no_condition([ "Outputs", name.to_s, "Condition" ], names, output["Condition"], "referred to by the output #{name}")
          end
        end

        # nil when the condition exists, or is an intrinsic whose value is not known here.
        def no_condition(at, names, condition, where)
          return if condition.is_a?(String) && names.condition?(condition)
          return if !condition.is_a?(String) && Template.intrinsic?(condition)

          error(at, "the condition #{Template.show(condition)}, #{where}, is not declared in the Conditions section",
            hint: "declare it with condition(name, Fn.equals(...))")
        end

        # An Fn::If's condition, a "Condition" inside Conditions, or an Fn::FindInMap's mapping.
        def inside(value, at, names)
          if Template.function?(value, "Fn::If") && value["Fn::If"].is_a?(Array) && value["Fn::If"][0].is_a?(String)
            no_condition(at + [ "Fn::If", "[0]" ], names, value["Fn::If"][0], "used in an Fn::If")
          elsif at.first == "Conditions" && Template.function?(value, "Condition") && value["Condition"].is_a?(String)
            no_condition(at, names, value["Condition"], "referenced from the Conditions section")
          elsif Template.function?(value, "Fn::FindInMap") && value["Fn::FindInMap"].is_a?(Array) && value["Fn::FindInMap"][0].is_a?(String)
            mapping = value["Fn::FindInMap"][0]
            unless names.mapping?(mapping)
              error(at, "the Fn::FindInMap names the mapping #{mapping.inspect}, which the template does not declare",
                hint: "declare it with mapping(#{mapping.inspect}, ...)")
            end
          end
        end
      end
      # V14: no cycle through Ref, Fn::GetAtt, Fn::Sub and DependsOn between resources.
      #
      # The CDK (cfn-include.ts, getOrCreateResource): "Found a cycle between resources in
      # the template: Bucket1 depends on Bucket2 depends on Bucket1". It follows the
      # references inside a resource's properties first and its DependsOn last, and it
      # stops at the first cycle; this walks in the same order and answers every cycle it
      # meets. The engine: F3004.
      class Cycles < Rule
        rule "V14"

        def call(context)
          resources = Template.resources(context.template)
          names = resources.keys.map(&:to_s)
          edges = resources.to_h { |name, body| [ name.to_s, targets(body, names) ] }
          issues = []
          explored = {}
          edges.each_key do |start|
            next if explored[start]

            found = {}
            follow(start, [], {}, edges, explored, found)
            found.each_value do |chain, root|
              issues << error([ "Resources", root ], "Found a cycle between resources in the template: #{chain.join(" depends on ")}",
                hint: "a resource cannot depend on one that depends on it: break the circle with an Fn::GetAtt, or restructure")
            end
          end
          issues
        end

        private

        # The resources a resource refers to, in the order the CDK reads them: those of its
        # properties first, then those of every other attribute, and what DependsOn names,
        # which may be one logical ID or a list of them. A plain string elsewhere is
        # data, not a reference: a policy whose PolicyName happens to be its own logical
        # ID is no cycle, and the corpus has one.
        def targets(body, names)
          properties = body["Properties"]
          properties = properties.reject { |key, _| key == "TemplateBody" } if body["Type"] == Sites::NESTED_STACK && properties.is_a?(Hash)
          depended = Array(body["DependsOn"]).select { |id| names.include?(id) }
          [ properties, body.reject { |attribute, _| attribute == "Properties" } ]
            .flat_map { |part| referred(part, names, []) }
            .concat(depended)
        end

        def referred(value, names, found)
          case value
          when Hash
            reference(value, names, found) || value.each_value { |item| referred(item, names, found) }
          when Array
            value.each { |item| referred(item, names, found) }
          end
          found
        end

        # True when the value is an intrinsic that names resources.
        def reference(value, names, found)
          if Template.function?(value, "Ref")
            found << value["Ref"] if names.include?(value["Ref"])
          elsif Template.function?(value, "Fn::GetAtt")
            target, = Template.get_att(value["Fn::GetAtt"])
            found << target if target && names.include?(target)
          elsif Template.function?(value, "Fn::Sub")
            string, supplied = substitution(value["Fn::Sub"])
            if string.is_a?(String)
              Template.variables(string) { |name| record(name, supplied, names, found) }
            end
          else
            return false
          end
          true
        end

        # Records the resource a variable of an Fn::Sub names, when it is one of this
        # template's. "${Id.Attribute}" names the resource Id.
        def record(name, supplied, names, found)
          return if name.empty? || supplied.key?(name)

          dot = name.index(".")
          reached = dot ? String(name[0, dot]) : name
          found << reached if names.include?(reached)
        end

        # [ the string, the names the Fn::Sub supplies itself ] of its argument.
        def substitution(argument)
          return [ argument, {} ] if argument.is_a?(String)
          return [ nil, {} ] unless argument.is_a?(Array)

          [ argument[0], argument[1].is_a?(Hash) ? argument[1] : {} ]
        end

        # Depth first from node. found gathers each cycle by the names it goes round, so
        # that one met twice is answered once: [ the chain as the CDK writes it, the root ].
        def follow(node, path, on_path, edges, explored, found)
          explored[node] = true
          on_path[node] = true
          path << node
          edges[node].each do |target|
            if on_path[target]
              cycle = path[path.index(target)..] + [ target ]
              found[cycle.rotate(cycle.index(cycle.min))] ||= [ path + [ target ], path.first ]
            elsif !explored[target]
              follow(target, path, on_path, edges, explored, found)
            end
          end
          path.pop
          on_path.delete(node)
        end
      end

      # V20: an Fn::Sub holds no empty "${}".
      #
      # The CDK refuses it as a name that is not in the template: "Element referenced in
      # Fn::Sub expression with logical ID: '' was not found in the template"
      # (cfn-parse.ts); architecture §6 gives it its own number.
      class EmptySubstitution < Rule
        rule "V20"

        def call(context)
          issues = []
          Sites.each(context) do |value, at, _parameters_only|
            next unless Template.function?(value, "Fn::Sub")

            argument = value["Fn::Sub"]
            string = argument.is_a?(Array) ? argument[0] : argument
            next unless string.is_a?(String) && empty_variable?(string)

            issues << error(at, "the Fn::Sub holds an empty variable, \"${}\"", hint: "name a logical ID, or supply a value in the map of the Fn::Sub")
          end
          issues
        end

        private

        # True when one of the variables of the string is empty, "${}".
        def empty_variable?(string)
          Template.variables(string) { |name| return true if name.empty? }
          false
        end
      end

      # V21: a short-form Fn::GetAtt ("Id.Attribute") has both parts.
      #
      # The CDK: "Short-form Fn::GetAtt must contain a '.' in its string argument, got:
      # 'Bucket1Arn'" (cfn-parse.ts).
      class ShortFormGetAtt < Rule
        rule "V21"

        def call(context)
          issues = []
          Sites.each(context) do |value, at, _parameters_only|
            next unless Template.function?(value, "Fn::GetAtt")

            argument = value["Fn::GetAtt"]
            if argument.is_a?(String)
              next if argument.include?(".")

              issues << error(at, "the short form of Fn::GetAtt must contain a \".\" in its string argument, got: #{argument.inspect}",
                hint: 'write "LogicalId.Attribute"')
            elsif argument.is_a?(Array)
              next if argument.size == 2 && argument.all? { |part| part.is_a?(String) || Template.intrinsic?(part) }

              issues << error(at, "Fn::GetAtt takes the logical ID of a resource and the name of one of its attributes",
                hint: 'write [ "LogicalId", "Attribute" ]')
            end
          end
          issues
        end
      end

      # V22: no Fn::GetAtt in the Conditions section.
      #
      # The CDK: "Using GetAtt in Condition definitions is not allowed" (cfn-include.ts,
      # the finder of getOrCreateCondition). The engine: E9101.
      class NoGetAttInConditions < Rule
        rule "V22"

        def call(context)
          issues = []
          Template.walk(Template.section(context.template, "Conditions"), "Conditions") do |value, at|
            next unless Template.function?(value, "Fn::GetAtt")

            issues << error(at, "Fn::GetAtt is not allowed in the Conditions section",
              hint: "a condition compares parameters and pseudo-parameters, with Ref and Fn::FindInMap")
          end
          issues
        end
      end
    end
  end
end
