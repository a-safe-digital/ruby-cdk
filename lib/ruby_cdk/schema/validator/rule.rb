# frozen_string_literal: true

require_relative "../../errors"
require_relative "template"

module RubyCdk
  module Validation
    # One warning. The pipeline fails a synthesis on every Issue a validator answers, so
    # a warning has to be told apart from an error: it is an Issue (everything that reads
    # one reads the other) that also answers warning? with true.
    class Warning < Issue
      def warning?
        true
      end

      # :warning here, :error for every other Issue.
      def severity
        :warning
      end
    end

    # True for a Warning, false for every other value: the one place that decides.
    def self.warning?(issue)
      issue.is_a?(Warning)
    end

    # What every rule is: an id and call. A rule never raises for a bad template: it
    # answers the issues it found, every one of them.
    class Rule
      class << self
        # The id of the rule, "V3". The class body sets it once, with `rule "V3"`.
        attr_reader :id

        private

        def rule(id)
          @id = id
        end
      end

      def id
        self.class.id
      end

      # The issues the rule finds in context.template: an Array of Issue and Warning, in the order of the template.
      def call(_context)
        raise NotImplementedError, "#{self.class} finds nothing"
      end

      private

      # path is an Array of segments, or the path already as text.
      def error(path, message, hint: nil)
        Issue.new(rule: id, path: at(path), message:, hint:)
      end

      def warning(path, message, hint: nil)
        Warning.new(rule: id, path: at(path), message:, hint:)
      end

      def at(path)
        path.is_a?(Array) ? Template.path(path) : path
      end
    end

    # Words for a message: the names closest to one that is wrong, and how lists read.
    module Text
      module_function

      # "a, b and c", for a message that lists.
      def list(items)
        items = items.map(&:to_s)
        case items.size
        when 0 then ""
        when 1 then items.first
        else "#{items[0..-2].join(', ')} and #{items.last}"
        end
      end

      # How far a name may be from another to be offered in its place.
      def near?(distance, length)
        distance <= (length < 8 ? 2 : 3)
      end

      # The names nearest to the one given, nearest first: those it is a suffix of, then
      # those within a small edit distance inside the same service ("AWS::S3"). At most
      # limit names, and none when nothing is close.
      def closest(given, names, limit: 3)
        service = given.include?("::") ? given[0, given.rindex("::")] : ""
        scored = names.reject { |name| name == given }.filter_map do |name|
          scope = service.empty? || name.start_with?("#{service}::") ? 0 : 1
          # The distance of a name of another length entirely is not worth computing.
          next if scope == 1 && (name.size - given.size).abs > 3

          [ name.end_with?(given) ? 0 : 1, scope, distance(Template.fold(given), Template.fold(name)), name ]
        end
        suffixes, others = scored.partition { |suffix, _, _, _| suffix.zero? }
        near = others.select { |_suffix, scope, edit, name| scope.zero? && near?(edit, name.size) }
        near = others.select { |_suffix, _scope, edit, name| near?(edit, name.size) } if near.empty?
        (suffixes.map(&:last) + near.sort_by { |_suffix, _scope, edit, name| [ edit, name ] }.map(&:last)).uniq.first(limit)
      end

      # The smallest number of single-character edits that turns one string into the other.
      def distance(left, right)
        row = (0..right.size).to_a
        left.each_char.with_index(1) do |char, i|
          previous = row[0]
          row[0] = i
          right.each_char.with_index(1) do |other, j|
            current = row[j]
            row[j] = [ row[j] + 1, row[j - 1] + 1, previous + (char == other ? 0 : 1) ].min
            previous = current
          end
        end
        row.last
      end
    end
  end
end
