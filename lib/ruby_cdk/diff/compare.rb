# frozen_string_literal: true

module RubyCdk
  module Diff
    # Whether two template values mean the same thing, and which entries of two
    # keyed sections differ.
    #
    # equal? is the CDK's deepEqual (cloudformation-diff, lib/diff/util.ts at
    # eca1b73d682d7763955bec30ab5dd52bbc4327b6), which is not a plain deep
    # equality on purpose, because CloudFormation is not strict either:
    #
    # - a numeric 10 and the literal "10" are equal (safeParseFloat there,
    #   number here, with JavaScript's Number rules: a String that names no
    #   number is NaN, and NaN equals nothing, which is why versions like
    #   "0.0.1" against "0.0.2" still count as a change);
    # - a boolean and its stringified counterpart are equal
    #   ("true" against true), for the same reason;
    # - a DependsOn list compares equal to the single value it wraps, and two
    #   lists compare equal whatever their order, elements matched one to one
    #   so duplicates count by multiplicity.
    module Compare
      module_function

      # True when the two values are equivalent, as above.
      def equal?(lvalue, rvalue)
        return true if lvalue == rvalue

        if (lvalue.is_a?(String) && boolean?(rvalue)) || (boolean?(lvalue) && rvalue.is_a?(String))
          return true if lvalue.to_s == rvalue.to_s
        end

        if lvalue.is_a?(String) || rvalue.is_a?(String)
          return true if number(lvalue) == number(rvalue)
        end

        return false unless same_kind?(lvalue, rvalue)

        if lvalue.is_a?(Array)
          return false unless lvalue.length == rvalue.length

          lvalue.each_with_index { |entry, index| return false unless equal?(entry, rvalue[index]) }
          return true
        end

        if lvalue.is_a?(Hash)
          return false unless lvalue.keys.length == rvalue.keys.length

          lvalue.each do |key, value|
            return false unless rvalue.key?(key)
            return false unless key == "DependsOn" ? depends_on_equal?(value, rvalue[key]) : equal?(value, rvalue[key])
          end
          return true
        end

        # Same kind, not equal under ==: two strings that differ, two numbers
        # that differ, nil against nil was taken by == at the top.
        false
      end

      # The DependsOn comparison of the CDK's dependsOnEqual: a one-element
      # list equals the bare value, two lists equal each other irrespective of
      # order, and two values that are not lists never equal each other here
      # (the normalizer makes lists of DependsOn before the comparison runs).
      def depends_on_equal?(lvalue, rvalue)
        if lvalue.is_a?(Array) != rvalue.is_a?(Array)
          list, other = lvalue.is_a?(Array) ? [ lvalue, rvalue ] : [ rvalue, lvalue ]
          return list.length == 1 && equal?(list.first, other)
        end

        return false unless lvalue.is_a?(Array)
        return false unless lvalue.length == rvalue.length

        unmatched = (0...rvalue.length).to_a
        lvalue.each do |entry|
          at = unmatched.find_index { |index| equal?(entry, rvalue[index]) }
          return false if at.nil?

          unmatched.delete_at(at)
        end
        true
      end

      # JavaScript's Number, for the numeric equivalence above. A String that
      # names no number, and any other kind of value, is NaN: equal to nothing,
      # not even to itself.
      def number(value)
        case value
        when Integer, Float then value.to_f
        when String
          stripped = value.strip
          return 0.0 if stripped.empty?

          parsed = begin
            Kernel.Float(stripped)
          rescue ArgumentError, TypeError
            nil
          end
          parsed || Float::NAN
        when nil then 0.0
        when true then 1.0
        when false then 0.0
        when Array
          elements = value.map { |entry| entry.is_a?(String) ? entry : (entry.is_a?(Array) ? entry.compact.join(",") : "") }
          number(elements.join(","))
        else Float::NAN
        end
      end

      # Every entry of both keyed maps, in the order the old one holds them and
      # then the new one's, so the comparison walks the template as it was
      # written. Yields the key and both values (nil for the side that lacks it).
      def keyed(old_map, new_map)
        old_map = {} unless old_map.is_a?(Hash)
        new_map = {} unless new_map.is_a?(Hash)
        keys = old_map.keys + (new_map.keys - old_map.keys)
        keys.each { |key| yield key, old_map[key], new_map[key] }
      end

      # True when the two values are of the same kind, in the sense the CDK's
      # typeof and Array.isArray checks make: strings with strings, numbers
      # with numbers, booleans with booleans, lists with lists, objects with
      # objects.
      def same_kind?(lvalue, rvalue)
        case [ lvalue.class, rvalue.class ]
        in [ String, String ] then true
        in [ TrueClass | FalseClass, TrueClass | FalseClass ] then true
        in [ Integer | Float, Integer | Float ] then true
        in [ Array, Array ] then true
        in [ Hash, Hash ] then true
        in [ NilClass, NilClass ] then true
        else false
        end
      end

      # True for true and false, and for nothing else.
      def boolean?(value)
        value == true || value == false
      end
    end
  end
end
