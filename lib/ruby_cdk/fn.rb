# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "lazy"

module RubyCdk
  # Every value here is a plain Hash in CloudFormation syntax.
  #
  #   Fn.ref("Table")                     => {"Ref" => "Table"}
  #   Fn.get_att(role, "Arn")             => {"Fn::GetAtt" => ["FnRole", "Arn"]}
  #   Fn.sub("${Table}")                  => {"Fn::Sub" => "${Table}"}
  #   Fn.join("", ["a", "b"])             => {"Fn::Join" => ["", ["a", "b"]]}
  #
  # A target may be a String, a Symbol or anything with a logical_id.
  #
  # The functions, and what each writes, were read in the CDK's
  # packages/aws-cdk-lib/core/lib/cfn-fn.ts at commit
  # 78649cb7cf7399204ed63f629964779eeaa8b37a. That file is the CDK's only Fn.
  #
  # As in the CDK, a function that can answer from its arguments does so at
  # once when nothing in them is deferred, and Fn.join is simplified when the
  # template is resolved: see minimal_join. Deferred means one of two things
  # here. An intrinsic composes at once, as a token does in the CDK. A Lazy,
  # which this tool has and the CDK has not, makes the function answer a Lazy
  # that runs again on what the argument resolves to: see now_or_later.
  module Fn
    # {"Ref" => "AWS::NoValue"}: leaves a property out of the template.
    NO_VALUE = { "Ref" => "AWS::NoValue" }.freeze

    module_function

    def ref(target)
      { "Ref" => logical_id_of(target, "Fn.ref") }
    end

    def get_att(target, attribute)
      { "Fn::GetAtt" => [ logical_id_of(target, "Fn.get_att"), attribute.to_s ] }
    end

    # With variables: Fn.sub("Hi ${Name}", "Name" => value).
    def sub(string, variables = {})
      if variables.empty?
        { "Fn::Sub" => string }
      else
        { "Fn::Sub" => [ string, variables.to_h { |key, value| [ name_of(key, "Fn.sub variables"), value ] } ] }
      end
    end

    # parts is the list of values to join, as one Array or as several arguments.
    # An empty list is an error, as it is in the CDK.
    #
    # A lone Hash is the list itself, not a list of one: Fn.join(",", Fn.get_azs)
    # joins what Fn::GetAZs answers. That is how a list CloudFormation computes
    # is joined, and it keeps such a join whole when it sits inside another one.
    # A lone Lazy is the list once it has resolved.
    def join(separator, *parts)
      list =
        if parts.length == 1 && parts.first.is_a?(Hash)
          parts.first
        else
          parts.flatten(1)
        end
      if parts.length == 1 && parts.first.is_a?(Lazy)
        return Lazy.new { |stack| join(separator, lazys_resolved(parts.first, stack)) }
      end

      Kernel.raise UsageError, "Fn.join requires at least one value to be provided" if list.empty?

      { "Fn::Join" => [ separator, list ] }
    end

    # Splits a string into a list. A literal string is split at once.
    #
    # With assumed_length the result is a list of known length, the first
    # assumed_length elements of the split, each an Fn::Select. Without it the
    # result is the Fn::Split itself, of a length only CloudFormation knows, and
    # Fn.select is then the only way to take an element out of it.
    def split(separator, string, assumed_length = nil)
      split_value = now_or_later(separator, string) do |with, source|
        if source.is_a?(String)
          Kernel.raise UsageError, "Fn.split takes a String separator, got #{with.inspect}" unless with.is_a?(String)

          source.empty? ? [ "" ] : (with.empty? ? source.chars : source.split(/#{Regexp.escape(with)}/, -1))
        else
          { "Fn::Split" => [ with, source ] }
        end
      end

      # A literal string was split at once, and the assumed length is not needed, as in the CDK.
      assumed_length.nil? || split_value.is_a?(Array) ? split_value : known_length(split_value, assumed_length)
    end

    # Like Fn.import_value, for a list of known length: the imported value is
    # split on delimiter, and the list holds its first assumed_length elements.
    def import_list_value(name, assumed_length, delimiter = ",")
      split(delimiter, import_value(name), assumed_length)
    end

    # The element at index of a list that is entirely known at once. Otherwise
    # an Fn::Select. The index is written as given: the CDK writes a number.
    #
    # Known at once is the CDK's rule: nothing anywhere in the list is an
    # intrinsic. A plain Hash or Array in it is fine.
    def select(index, list)
      now_or_later(index, list) do |at, from|
        check_list!(from, "Fn.select")
        if at.is_a?(Integer) && from.is_a?(Array) && from.none? { |item| intrinsic_inside?(item) }
          from[at]
        else
          { "Fn::Select" => [ at, from ] }
        end
      end
    end

    # The domain of a URL: Fn.parse_domain_name("https://test.com/") is
    # "test.com". A literal URL is parsed at once.
    #
    # Read in packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.parseDomainName.
    def parse_domain_name(url)
      now_or_later(url) do |address|
        select(0, split("/", select(1, split("//", address))))
      end
    end

    # count CIDR blocks out of ip_block, each with size_mask subnet bits, as
    # Fn::Cidr. count is 1 to 256. The result is a list CloudFormation computes:
    # take an element with Fn.select. Read in
    # packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.cidr and FnCidr.
    def cidr(ip_block, count, size_mask = nil)
      now_or_later(ip_block, count, size_mask) do |block, wanted, mask|
        if wanted.is_a?(Integer) && !(1..256).cover?(wanted)
          Kernel.raise UsageError, "Fn::Cidr's count attribute must be between 1 and 256, #{wanted} was provided."
        end

        { "Fn::Cidr" => [ block, wanted, *([ mask ] unless mask.nil?) ] }
      end
    end

    # The value of the output output_name of the stack stack_name, without an
    # export. region defaults to the stack's own and role_arn to its execution
    # role. Read in packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.getStackOutput and FnGetStackOutput.
    def get_stack_output(stack_name, output_name, region = nil, role_arn = nil)
      { "Fn::GetStackOutput" => { "StackName" => stack_name, "OutputName" => output_name, "Region" => region, "RoleArn" => role_arn }.compact }
    end

    # The value at two keys of a mapping. default_value is what CloudFormation
    # answers when a key is missing; without it a missing key is an error at
    # deploy. Read in packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.findInMap and FnFindInMap.
    def find_in_map(mapping, top_level_key, second_level_key, default_value: nil)
      keys = [ mapping.to_s, top_level_key, second_level_key ]
      keys << { "DefaultValue" => default_value } unless default_value.nil?

      { "Fn::FindInMap" => keys }
    end

    # The macro macro_name, run on this template with parameters: Fn::Transform.
    # The template must declare the macro, with Stack#transform. Read in
    # packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.transform and FnTransform.
    def transform(macro_name, parameters)
      unless parameters.is_a?(Hash)
        Kernel.raise UsageError, "Fn.transform takes a Hash of parameters, got #{parameters.inspect}"
      end

      { "Fn::Transform" => { "Name" => macro_name, "Parameters" => parameters } }
    end

    # The object as a JSON string. One that holds an intrinsic is written as
    # Fn::ToJsonString, for CloudFormation to do at deploy; it needs the
    # AWS::LanguageExtensions transform, which synthesis adds. Read in
    # packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.toJsonString and FnToJsonString.
    def to_json_string(object)
      now_or_later(object) do |value|
        intrinsic_inside?(value) ? { "Fn::ToJsonString" => value } : JSON.generate(value)
      end
    end

    # The number of elements of an Array. Of anything else that is a list
    # CloudFormation computes, an intrinsic, it is Fn::Length, which needs the
    # AWS::LanguageExtensions transform, which synthesis adds. Read in
    # packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.len and FnLength.
    def len(array)
      now_or_later(array) do |value|
        if value.is_a?(Array)
          value.length
        elsif value.is_a?(Hash)
          { "Fn::Length" => value }
        else
          Kernel.raise UsageError, "Fn.len needs an array, got #{value.inspect}"
        end
      end
    end

    # All the values of a parameter of an AWS-specific type, such as
    # "AWS::EC2::VPC::Id": Fn::RefAll. Read in
    # packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.refAll and FnRefAll.
    def ref_all(parameter_type)
      { "Fn::RefAll" => parameter_type }
    end

    # An attribute of a parameter of an AWS-specific type: Fn::ValueOf. Read in
    # packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.valueOf and FnValueOf.
    def value_of(parameter_or_logical_id, attribute)
      { "Fn::ValueOf" => [ parameter_or_logical_id, attribute ] }
    end

    # An attribute of every value of a parameter of an AWS-specific type:
    # Fn::ValueOfAll. Read in packages/aws-cdk-lib/core/lib/cfn-fn.ts,
    # Fn.valueOfAll and FnValueOfAll.
    def value_of_all(parameter_type, attribute)
      { "Fn::ValueOfAll" => [ parameter_type, attribute ] }
    end

    # What the CDK does to an Fn::Join when it resolves a template
    # (minimalCloudFormationJoin, in packages/aws-cdk-lib/core/lib/private/cloudformation-lang.ts):
    # an Fn::Join nested inside another one with the same delimiter is spliced
    # in, and two neighbouring literals become one string. Returns the
    # simplified list: one element long when the whole join is that element.
    def minimal_join(delimiter, values)
      values = values.dup
      index = 0
      while index < values.length
        element = values[index]
        if nested_join?(element, delimiter)
          values[index, 1] = element["Fn::Join"][1]
        elsif index.positive? && concatable?(values[index - 1]) && concatable?(element)
          values[index - 1] = "#{literal(values[index - 1])}#{delimiter}#{literal(element)}"
          values.delete_at(index)
        else
          index += 1
        end
      end
      values
    end

    def base64(string)
      { "Fn::Base64" => string }
    end

    def import_value(name)
      { "Fn::ImportValue" => name.to_s }
    end

    # With no region, the region of the stack, as in the CDK: an empty string.
    def get_azs(region = "")
      { "Fn::GetAZs" => region || "" }
    end

    # condition: the name of a condition, or anything with a name.
    def if(condition, if_true, if_false)
      { "Fn::If" => [ condition_name(condition, "Fn.if"), if_true, if_false ] }
    end

    def equals(left, right)
      { "Fn::Equals" => [ left, right ] }
    end

    def and_(*conditions)
      { "Fn::And" => conditions }
    end

    def or_(*conditions)
      { "Fn::Or" => conditions }
    end

    def not_(condition)
      { "Fn::Not" => [ condition ] }
    end

    # True when value is in the list: Fn::Contains. Read in
    # packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.conditionContains and FnContains.
    def contains(list, value)
      { "Fn::Contains" => [ list, value ] }
    end

    # True when value equals every member of the list: Fn::EachMemberEquals. Read in
    # packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.conditionEachMemberEquals and FnEachMemberEquals.
    def each_member_equals(list, value)
      { "Fn::EachMemberEquals" => [ list, value ] }
    end

    # True when every member of list is also in matches: Fn::EachMemberIn. Read in
    # packages/aws-cdk-lib/core/lib/cfn-fn.ts, Fn.conditionEachMemberIn and FnEachMemberIn.
    def each_member_in(list, matches)
      { "Fn::EachMemberIn" => [ list, matches ] }
    end

    # private below

    # The rule of every function that computes from its arguments. With no Lazy
    # in them the block runs now. With one anywhere in them the function answers
    # a Lazy that runs the block once, when the template is resolved, on what
    # every Lazy among them has resolved to. The block must answer, never
    # return: it outlives the function that wrote it.
    def now_or_later(*arguments, &compute)
      return compute.call(*arguments) unless arguments.any? { |argument| lazy_inside?(argument) }

      Lazy.new { |stack| compute.call(*arguments.map { |argument| lazys_resolved(argument, stack) }) }
    end

    # The first assumed_length elements of a list CloudFormation computes, each an Fn::Select.
    def known_length(list, assumed_length)
      unless assumed_length.is_a?(Integer) && assumed_length >= 0
        Kernel.raise UsageError, "Fn.split: assumed_length must be an Integer of at least 0, got #{assumed_length.inspect}"
      end

      Array.new(assumed_length) { |index| select(index, list) }
    end

    def check_list!(list, caller)
      return if list.is_a?(Array) || list.is_a?(Hash)

      Kernel.raise UsageError, "#{caller} takes an Array or a function that returns a list, got #{list.inspect}"
    end

    def logical_id_of(target, caller)
      return target if target.is_a?(String)
      return target.name if target.is_a?(Symbol)
      return target.logical_id.to_s if target.respond_to?(:logical_id)

      Kernel.raise UsageError, "#{caller} takes a resource, a parameter or a logical ID, got #{target.inspect}"
    end

    def condition_name(condition, caller)
      return condition if condition.is_a?(String)
      return condition.name if condition.is_a?(Symbol)
      return condition.name.to_s if condition.respond_to?(:name)

      Kernel.raise UsageError, "#{caller} takes a condition the stack declared, or its name, got #{condition.inspect}"
    end

    def name_of(key, caller)
      return key if key.is_a?(String)
      return key.name if key.is_a?(Symbol)

      Kernel.raise UsageError, "The keys of #{caller} must be Strings or Symbols, got #{key.inspect}"
    end

    def nested_join?(value, delimiter)
      return false unless value.is_a?(Hash) && value.size == 1 && value.key?("Fn::Join")

      pair = value["Fn::Join"]
      pair.is_a?(Array) && pair[0] == delimiter && pair[1].is_a?(Array)
    end

    def concatable?(value)
      value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Float)
    end

    # An intrinsic: a Hash with one key, "Ref" or a name that starts with
    # "Fn::". The CDK's isIntrinsic, in
    # packages/aws-cdk-lib/core/lib/private/cloudformation-lang.ts.
    def intrinsic?(value)
      return false unless value.is_a?(Hash) && value.size == 1

      key = value.keys.first
      key == "Ref" || (key.is_a?(String) && key.start_with?("Fn::"))
    end

    # An intrinsic anywhere inside: a value CloudFormation computes at deploy.
    def intrinsic_inside?(value)
      case value
      when Hash
        intrinsic?(value) || value.values.any? { |item| intrinsic_inside?(item) }
      when Array
        value.any? { |item| intrinsic_inside?(item) }
      else
        false
      end
    end

    # A Lazy anywhere inside.
    def lazy_inside?(value)
      case value
      when Lazy
        true
      when Hash
        value.values.any? { |item| lazy_inside?(item) }
      when Array
        value.any? { |item| lazy_inside?(item) }
      else
        false
      end
    end

    # value with every Lazy in it resolved, and what each resolved to gone
    # through as well.
    def lazys_resolved(value, stack)
      case value
      when Lazy
        lazys_resolved(value.resolve(stack), stack)
      when Hash
        value.to_h { |key, item| [ key, lazys_resolved(item, stack) ] }
      when Array
        value.map { |item| lazys_resolved(item, stack) }
      else
        value
      end
    end

    # A literal the way a join writes it: the way JavaScript prints a number,
    # so 1.0 is written "1".
    def literal(value)
      value.is_a?(Float) && value.to_i.to_f == value ? value.to_i.to_s : value.to_s
    end
    private_class_method :now_or_later, :known_length, :check_list!, :logical_id_of, :condition_name, :name_of, :nested_join?,
      :concatable?, :intrinsic?, :intrinsic_inside?, :lazy_inside?, :lazys_resolved, :literal
  end
end
