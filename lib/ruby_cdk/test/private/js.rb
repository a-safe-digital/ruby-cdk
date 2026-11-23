# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/matching/lib (the messages of the matcher engine)
#           and packages/aws-cdk-lib/assertions/lib/private (the messages of the template)
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: the CDK has no file to translate here. Its engine is JavaScript and
#   builds its messages with typeof, String(), JSON.stringify, === and
#   localeCompare; this file reproduces those five in Ruby, so that a failure
#   reads here as it reads there. UNDEFINED is this tool's own: Ruby needs a way
#   to write what JavaScript writes as undefined, which is not null.

require "json"

module RubyCdk
  module Test
    # Stands where JavaScript writes `undefined`: a key that is present without a
    # value, an index past the end of an array. It is not nil, which is JSON's
    # null. The CDK tells the two apart (`Match.absent()` accepts one and refuses
    # the other), so a template written by hand in Ruby can say which one it means.
    #
    # Not in the CDK.
    UNDEFINED = Object.new
    UNDEFINED.define_singleton_method(:to_s) { "undefined" }
    UNDEFINED.define_singleton_method(:inspect) { "undefined" }
    UNDEFINED.freeze

    module Private
      # Internal to the matcher engine and to the template. Not part of the public API.
      module Js
        module_function

        # What JSON.stringify returns nothing for.
        NO_JSON = Object.new.freeze
        private_constant :NO_JSON

        # JavaScript `typeof`, quirk included: null is 'object' there.
        def typeof(value)
          if value.equal?(UNDEFINED)
            "undefined"
          elsif value.nil?
            "object"
          elsif value == true || value == false
            "boolean"
          elsif value.is_a?(Numeric)
            "number"
          elsif value.is_a?(String)
            "string"
          elsif value.is_a?(Symbol)
            "symbol"
          elsif value.is_a?(Proc) || value.is_a?(Method)
            "function"
          else
            "object"
          end
        end

        def nullish?(value)
          value.nil? || value.equal?(UNDEFINED)
        end

        # JavaScript: `value && typeof value === 'object'`. True of neither null nor undefined.
        def object?(value)
          !nullish?(value) && !primitive?(value)
        end

        def primitive?(value)
          value.nil? || value.equal?(UNDEFINED) || value.instance_of?(TrueClass) || value.instance_of?(FalseClass) ||
            value.is_a?(Numeric) || value.is_a?(String) || value.is_a?(Symbol)
        end

        # JavaScript `===`: primitives by value, everything else by identity.
        def strict_equal?(left, right)
          return left.equal?(right) unless primitive?(left)

          left == right
        end

        # JavaScript `String(value)`.
        def string(value)
          if value.is_a?(String)
            value
          elsif value.equal?(UNDEFINED)
            "undefined"
          elsif value.nil?
            "null"
          elsif value == true || value == false
            value.to_s
          elsif value.is_a?(Integer)
            value.to_s
          elsif value.is_a?(Float)
            number_string(value)
          elsif value.is_a?(Symbol)
            value.to_s
          elsif value.is_a?(Array)
            value.map { |element| nullish?(element) ? "" : string(element) }.join(",")
          else
            "[object Object]"
          end
        end

        # How JavaScript prints a number: 2.0 is "2", and nothing Ruby writes as
        # 1.0e+21 keeps the ".0". Only used in messages.
        def number_string(value)
          return value.to_s unless value.finite?
          return value.to_i.to_s if (value % 1).zero? && value.abs < 1e21

          sign = value.negative? ? "-" : ""
          digits, exponent = shortest_digits(value.abs)
          if exponent > 20 || exponent < -6
            fraction = digits.length > 1 ? ".#{digits[1..]}" : ""
            "#{sign}#{digits[0]}#{fraction}e#{exponent.negative? ? "-" : "+"}#{exponent.abs}"
          elsif exponent >= digits.length - 1
            "#{sign}#{digits}#{"0" * (exponent - digits.length + 1)}"
          elsif exponent >= 0
            "#{sign}#{digits[0..exponent]}.#{digits[(exponent + 1)..]}"
          else
            "#{sign}0.#{"0" * (-exponent - 1)}#{digits}"
          end
        end

        # The shortest digits that still round-trip, and the power of ten of the first.
        def shortest_digits(magnitude)
          match = magnitude.to_s.match(/\A(\d)(?:\.(\d+))?(?:e([+-]\d+))?\z/)
          return [ magnitude.to_s, 0 ] unless match

          whole, fraction, power = match.captures
          digits = "#{whole}#{fraction}".sub(/0+\z/, "")
          exponent = if power
            power.to_i
          elsif whole == "0"
            -(fraction.index(/[1-9]/) + 1)
          else
            whole.length - 1
          end
          [ digits, exponent ]
        end

        # JavaScript `JSON.stringify(value)`: compact text, or indented text when
        # an indent is given. nil where JavaScript returns undefined.
        def json(value, indent = nil)
          converted = native(value)
          return nil if converted.equal?(NO_JSON)

          indent ? JSON.pretty_generate(converted, indent: " " * indent) : JSON.generate(converted)
        end

        # JSON.stringify, with 'undefined' where JavaScript prints nothing.
        def jsonify(value)
          json(value) || "undefined"
        end

        # The value as Ruby's JSON library prints it as JavaScript would: a Float
        # that is a whole number is an Integer there ("2", not "2.0"), a number
        # that is not finite is null, and what JavaScript leaves out is NO_JSON.
        def native(value)
          case value
          when Hash
            object_keys(value).each_with_object({}) do |key, converted_hash|
              converted = native(value[key])
              next if converted.equal?(NO_JSON)

              converted_hash[key.to_s] = converted
            end
          when Array
            value.map do |item|
              converted = native(item)
              converted.equal?(NO_JSON) ? nil : converted
            end
          when Float
            return nil unless value.finite?

            (value % 1).zero? && value.abs < 1e21 ? value.to_i : value
          when UNDEFINED, Proc, Method, Symbol
            NO_JSON
          else
            value
          end
        end

        # A template or a pattern as JavaScript would have held it: a Symbol is
        # Ruby's way of writing a JSON string, so it becomes one, as a key or as a
        # value. Matchers are left alone. Nothing of the caller's is modified.
        #
        # Not in the CDK: JavaScript has no symbols.
        def normalize(value)
          case value
          when Hash
            value.to_h { |key, item| [ key.is_a?(Symbol) ? key.to_s : key, normalize(item) ] }
          when Array
            value.map { |item| normalize(item) }
          when Symbol
            value.to_s
          else
            value
          end
        end

        # A copy of the arrays and hashes of a value. Everything else is shared.
        def deep_copy(value)
          case value
          when Hash
            value.to_h { |key, item| [ key, deep_copy(item) ] }
          when Array
            value.map { |item| deep_copy(item) }
          else
            value
          end
        end

        # JavaScript `Object.keys`: own keys in order, the ones that read as array
        # indexes first and by number. Throws where JavaScript throws.
        def object_keys(value)
          if value.is_a?(Hash)
            indexed, other = value.keys.partition { |key| key.is_a?(String) && key.match?(/\A(?:0|[1-9]\d*)\z/) }
            indexed.sort_by(&:to_i) + other
          elsif value.is_a?(Array)
            (0...value.length).map(&:to_s)
          else
            Kernel.raise TypeError, "Cannot convert undefined or null to object" if nullish?(value)

            []
          end
        end

        # JavaScript `Object.entries`.
        def entries(value)
          object_keys(value).map do |key|
            item = value.is_a?(Hash) ? value[key] : value[key.to_i]
            [ key, item ]
          end
        end

        # JavaScript `value[key]`: UNDEFINED when there is nothing there.
        def get(value, key)
          if value.is_a?(Hash)
            value.key?(key) ? value[key] : UNDEFINED
          elsif value.is_a?(Array)
            index = key.is_a?(String) && key.match?(/\A\d+\z/) ? key.to_i : nil
            index && index < value.length ? value[index] : UNDEFINED
          else
            UNDEFINED
          end
        end

        # JavaScript `key in value`. Throws where JavaScript throws.
        def in?(key, value)
          if value.is_a?(Hash)
            value.key?(key)
          elsif value.is_a?(Array)
            key.is_a?(String) && key.match?(/\A\d+\z/) && key.to_i < value.length
          else
            Kernel.raise TypeError, "Cannot use 'in' operator to search for '#{key}' in #{string(value)}"
          end
        end

        def trim_end(value)
          value.gsub(/\s+\z/, "")
        end

        # An abridged version of a value: a long array is [ ... ], an object with
        # more than one key is { ... }. One of renderMismatch()'s inner functions.
        def render_abridged(value)
          if value.is_a?(Array)
            case value.length
            when 0
              "[]"
            when 1
              "[ #{render_abridged(value[0])} ]"
            when 2
              if value.all? { |element| [ "number", "boolean", "string" ].include?(typeof(element)) }
                "[ #{value.map { |element| render_abridged(element) }.join(", ")} ]"
              else
                "[ ... ]"
              end
            else
              "[ ... ]"
            end
          elsif object?(value)
            keys = object_keys(value)
            case keys.length
            when 0
              "{}"
            when 1
              "{ #{json(keys[0])}: #{render_abridged(get(value, keys[0]))} }"
            else
              "{ ... }"
            end
          else
            jsonify(value)
          end
        end

        # Move `!!` in front of the indentation of every line that starts with it.
        def move_markers_to_front(value)
          value.gsub(/^(\s+)!!/) do
            spaces = Regexp.last_match(1) || ""
            "!!#{spaces[0, [ spaces.length - 2, 0 ].max]}"
          end
        end

        # String.prototype.localeCompare as Node does it with no locale given
        # (ICU's root collation), as far as pure Ruby gets: letters compare without
        # regard to case, and among equal ones the lower-case spelling comes
        # first. Digits come after punctuation and before letters, as there.
        def locale_compare(left, right)
          result = collation_key(left) <=> collation_key(right)
          result.zero? ? left <=> right : result
        end

        def collation_key(value)
          primary = value.downcase.chars.map { |char| char.match?(/[a-z0-9]/) || char.ord < 0x30 ? char : "/" }.join
          [ primary, value.chars.map { |char| char == char.downcase ? 0 : 1 } ]
        end
      end
    end
  end
end
