# frozen_string_literal: true

module RubyCdk
  # Every value here is a plain Hash in CloudFormation syntax.
  #
  #   Fn.ref("Table")                     => {"Ref" => "Table"}
  #   Fn.get_att(role, "Arn")             => {"Fn::GetAtt" => ["FnRole", "Arn"]}
  #   Fn.sub("${Table}")                  => {"Fn::Sub" => "${Table}"}
  #   Fn.join("", ["a", "b"])             => {"Fn::Join" => ["", ["a", "b"]]}
  #
  # A target may be a String, a Symbol or anything with a logical_id.
  module Fn
    # {"Ref" => "AWS::NoValue"}: leaves a property out of the template.
    NO_VALUE = { "Ref" => "AWS::NoValue" }.freeze

    module_function

    def ref(target)
      { "Ref" => logical_id_of(target) }
    end

    def get_att(target, attribute)
      { "Fn::GetAtt" => [ logical_id_of(target), attribute.to_s ] }
    end

    # With variables: Fn.sub("Hi ${Name}", "Name" => value).
    def sub(string, variables = {})
      if variables.empty?
        { "Fn::Sub" => string }
      else
        { "Fn::Sub" => [ string, variables.to_h.transform_keys(&:to_s) ] }
      end
    end

    def join(separator, *parts)
      { "Fn::Join" => [ separator, parts.flatten(1) ] }
    end

    def select(index, list)
      { "Fn::Select" => [ index.to_s, list ] }
    end

    def split(separator, string)
      { "Fn::Split" => [ separator, string ] }
    end

    def base64(string)
      { "Fn::Base64" => string }
    end

    def import_value(name)
      { "Fn::ImportValue" => name.to_s }
    end

    def get_azs(region = "AWS::Region")
      { "Fn::GetAZs" => region }
    end

    def find_in_map(mapping, top_level_key, second_level_key)
      { "Fn::FindInMap" => [ mapping.to_s, top_level_key, second_level_key ] }
    end

    # condition: the name of a condition, or anything with a name.
    def if(condition, if_true, if_false)
      { "Fn::If" => [ condition_name(condition), if_true, if_false ] }
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
    def logical_id_of(target)
      return target.logical_id.to_s if target.respond_to?(:logical_id)

      target.to_s
    end

    def condition_name(condition)
      return condition.name.to_s if condition.respond_to?(:name)

      condition.to_s
    end
    private_class_method :logical_id_of
    private_class_method :condition_name
  end
end
