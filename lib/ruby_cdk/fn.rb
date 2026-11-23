# frozen_string_literal: true

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
  # As in the CDK (cfn-fn.ts), Fn.select and Fn.split answer at once when
  # nothing in them is deferred, and Fn.join is simplified when the template is
  # resolved: see minimal_join.
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
    def join(separator, *parts)
      list = parts.flatten(1)
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
      if string.is_a?(String)
        Kernel.raise UsageError, "Fn.split takes a String separator, got #{separator.inspect}" unless separator.is_a?(String)

        return [ "" ] if string.empty?
        return string.chars if separator.empty?
        return string.split(/#{Regexp.escape(separator)}/, -1)
      end

      intrinsic = { "Fn::Split" => [ separator, string ] }
      return intrinsic if assumed_length.nil?

      unless assumed_length.is_a?(Integer) && assumed_length >= 0
        Kernel.raise UsageError, "Fn.split: assumed_length must be an Integer of at least 0, got #{assumed_length.inspect}"
      end

      Array.new(assumed_length) { |index| select(index, intrinsic) }
    end

    # Like Fn.import_value, for a list of known length: the imported value is
    # split on delimiter, and the list holds its first assumed_length elements.
    def import_list_value(name, assumed_length, delimiter = ",")
      split(delimiter, import_value(name), assumed_length)
    end

    # The element at index of a list that is entirely known at once. Otherwise
    # an Fn::Select. The index is written as given: the CDK writes a number.
    #
    # Known at once is the CDK's rule: nothing anywhere in the list is deferred,
    # neither a Lazy nor an intrinsic. A plain Hash or Array in it is fine.
    def select(index, list)
      unless list.is_a?(Array) || list.is_a?(Hash)
        Kernel.raise UsageError, "Fn.select takes an Array or a function that returns a list, got #{list.inspect}"
      end
      if index.is_a?(Integer) && list.is_a?(Array) && list.none? { |item| deferred?(item) }
        return list[index]
      end

      { "Fn::Select" => [ index, list ] }
    end

    # What the CDK does to an Fn::Join when it resolves a template
    # (minimalCloudFormationJoin): an Fn::Join nested inside another one with
    # the same delimiter is spliced in, and two neighbouring literals become
    # one string. Returns the simplified list: one element long when the whole
    # join is that element.
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

    def find_in_map(mapping, top_level_key, second_level_key)
      { "Fn::FindInMap" => [ mapping.to_s, top_level_key, second_level_key ] }
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

    # private below
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

    # What stands for a value CloudFormation computes: a Lazy, or an intrinsic,
    # anywhere inside.
    def deferred?(value)
      case value
      when Lazy
        true
      when Hash
        intrinsic?(value) || value.values.any? { |item| deferred?(item) }
      when Array
        value.any? { |item| deferred?(item) }
      else
        false
      end
    end

    # A Hash with one key, "Ref" or a name that starts with "Fn::": the CDK's isIntrinsic.
    def intrinsic?(value)
      return false unless value.is_a?(Hash) && value.size == 1

      key = value.keys.first
      key == "Ref" || (key.is_a?(String) && key.start_with?("Fn::"))
    end

    # A literal the way a join writes it: the way JavaScript prints a number,
    # so 1.0 is written "1".
    def literal(value)
      value.is_a?(Float) && value.to_i.to_f == value ? value.to_i.to_s : value.to_s
    end
    private_class_method :logical_id_of, :condition_name, :name_of, :nested_join?, :concatable?, :deferred?, :intrinsic?, :literal
  end
end
