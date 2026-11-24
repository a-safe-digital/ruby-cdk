# frozen_string_literal: true

module RubyCdk
  module Nag
    # Raised inside a rule, by a value reader, when the value a check needs is
    # not a literal. It never leaves the rule: Rule#check turns it into a Skipped.
    class Undecided < StandardError
      attr_reader :path, :reason

      # reason completes the sentence that starts with path: "is a Ref", "is not a string".
      def initialize(path, reason)
        @path = path
        @reason = reason
        super("#{path} #{reason}")
      end
    end

    # The value helper. It tells a literal from a dynamic value the same way for
    # every rule, so that no rule decides on its own what a Ref is.
    #
    # A dynamic value is an intrinsic function: a Hash with a "Ref" key, or with
    # any key that starts with "Fn::", and anything that contains one. A rule
    # that needs a literal and meets one skips that check and counts it.
    #
    # One intrinsic is the exception. {"Ref" => "AWS::NoValue"} removes the
    # property it is the value of, so it is read as "absent", never as dynamic:
    # the same reading cfn-nag's BooleanBaseRule gives it (spec/test_templates
    # use it for exactly that).
    #
    # So is one Fn::Sub. An Fn::Sub whose string holds no ${...} variable
    # resolves to that string, so it is read as the literal it is; only an
    # Fn::Sub with variables is dynamic.
    module Values
      # The property this is the value of is left out of the resource.
      NO_VALUE = { "Ref" => "AWS::NoValue" }.freeze

      # The dynamic references CloudFormation resolves to a secret at deploy
      # time. cfn-nag's enforce_string_or_dynamic_reference.rb exempts exactly
      # these two, and nothing else.
      SECRET_DYNAMIC_REFERENCE_PREFIXES = [ "{{resolve:secretsmanager:", "{{resolve:ssm-secure:" ].freeze

      # A ${...} in an Fn::Sub string that stands for a variable. ${!Word} is
      # how a literal ${Word} is written, and is not one.
      SUB_VARIABLE = /\$\{(?!!)[^}]*\}/.freeze

      # Longest form of a value in a message or a reason.
      PREVIEW_LENGTH = 60

      module_function

      # True only for an intrinsic function itself: {"Ref" => ...} or {"Fn::..." => ...}.
      # One is the exception: an Fn::Sub whose string holds no variable is
      # the String it holds, and is not dynamic.
      def intrinsic?(value)
        return false if literal_sub?(value)

        value.is_a?(Hash) && (value.key?("Ref") || value.keys.any? { |key| key.is_a?(String) && key.start_with?("Fn::") })
      end

      # True when value, or anything inside it, is an intrinsic function.
      def dynamic?(value)
        return false if literal_sub?(value)

        case value
        when Array
          value.any? { |item| dynamic?(item) }
        when Hash
          intrinsic?(value) || value.values.any? { |item| dynamic?(item) }
        else
          false
        end
      end

      # The String an Fn::Sub without variables resolves to.
      def literal_sub_string(value)
        written = value["Fn::Sub"]
        written.is_a?(Array) ? written.first : written
      end

      # {"Fn::Sub" => "x"} or {"Fn::Sub" => ["x", ...]} where "x" holds no
      # ${...} variable: CloudFormation leaves the string as it is.
      def literal_sub?(value)
        return false unless value.is_a?(Hash) && value.keys == [ "Fn::Sub" ]

        text = value["Fn::Sub"].is_a?(Array) ? value["Fn::Sub"].first : value["Fn::Sub"]
        text.is_a?(String) && !SUB_VARIABLE.match?(text)
      end

      # True when value removes the property it is written in.
      def no_value?(value)
        value == NO_VALUE
      end

      # True for a String that CloudFormation replaces with the value of a
      # secret: not a literal in the clear, whatever the template says.
      def secret_dynamic_reference?(value)
        value.is_a?(String) && SECRET_DYNAMIC_REFERENCE_PREFIXES.any? { |prefix| value.start_with?(prefix) } && value.end_with?("}}")
      end

      # A short form of a value for a message. Never raises.
      def preview(value)
        text = value.inspect
        text.length > PREVIEW_LENGTH ? "#{text[0, PREVIEW_LENGTH]}..." : text
      end
    end

    # Reads the literal values of one resource, or of one part of it, by path.
    #
    # A path is written with the template's own keys: "Properties.Encrypted",
    # "Properties.SecurityGroupIngress[1].CidrIp". A reader that was positioned
    # at a path (at, sub) reads relative to it.
    #
    # Every reader method returns nil for a value that is absent or is
    # AWS::NoValue, and raises Undecided for one that is dynamic or is not of
    # the kind asked for. A rule calls them inside Rule#check, which records
    # the Undecided and carries on.
    class Reader
      # One step of a path: a key, and the index of a list item when the key ends in "[n]".
      SEGMENT = /\A([^.\[\]]+)(?:\[(\d+)\])?\z/
      INTEGER = /\A\s*-?\d+\s*\z/

      # root: the Hash (or nil) the paths are read from. prefix: the path root stands for.
      def initialize(root, prefix = "")
        @root = root
        @prefix = prefix
      end

      # A reader for the Hash or the list item at path, with path as its prefix.
      def at(path)
        Reader.new(raw(path), join(@prefix, path))
      end

      # A reader for a document that was parsed out of the template, such as a
      # policy document written as a JSON string, filed under path.
      def sub(path, document)
        Reader.new(document, join(@prefix, path))
      end

      # The path a reader at this position reads for path, written in the resource's own terms.
      def full_path(path)
        join(@prefix, path)
      end

      # The value at path as it is written: nil when absent or AWS::NoValue.
      def raw(path)
        walk(path, dynamic: :raise)
      end

      # The value at path without ever raising: an intrinsic comes back as it
      # is written. For describing a finding, not for deciding one.
      def peek(path)
        walk(path, dynamic: :keep)
      end

      # True when a value other than AWS::NoValue is written at path.
      def present?(path)
        !raw(path).nil?
      end

      # The String at path.
      def string(path)
        value = raw(path)
        return nil if value.nil?
        return value if value.is_a?(String)

        raise Undecided.new(join(@prefix, path), "is #{Values.preview(value)}, not a string")
      end

      # The Integer at path. Templates written before the schema was strict
      # carry numbers as strings, so "22" reads as 22.
      def integer(path)
        value = raw(path)
        return nil if value.nil?
        return value if value.is_a?(Integer)
        return Integer(value, 10) if value.is_a?(String) && INTEGER.match?(value)

        raise Undecided.new(join(@prefix, path), "is #{Values.preview(value)}, not an integer")
      end

      # true or false at path. "true" and "false", in any case, read as the
      # booleans they name, as they do in cfn-nag's truthy?.
      def boolean(path)
        value = raw(path)
        return nil if value.nil?
        return value if value == true || value == false
        if value.is_a?(String)
          return true if value.strip.casecmp?("true")
          return false if value.strip.casecmp?("false")
        end

        raise Undecided.new(join(@prefix, path), "is #{Values.preview(value)}, not a boolean")
      end

      # The object (a Hash) at path.
      def object(path)
        value = raw(path)
        return nil if value.nil?
        return value if value.is_a?(Hash)

        raise Undecided.new(join(@prefix, path), "is #{Values.preview(value)}, not an object")
      end

      # The String at path, or every String of the list at path.
      def strings(path)
        value = raw(path)
        return [] if value.nil?
        return [ value ] if value.is_a?(String)
        if value.is_a?(Array)
          return value.map do |item|
            item.is_a?(String) ? item : raise(Undecided.new(join(@prefix, path), "holds #{Values.preview(item)}, not a string"))
          end
        end

        raise Undecided.new(join(@prefix, path), "is #{Values.preview(value)}, neither a string nor a list")
      end

      # Every key of the Hash at path. An intrinsic among the values does not
      # matter here: only the key is returned.
      def keys(path)
        value = raw(path)
        return [] if value.nil?
        return value.keys if value.is_a?(Hash) && value.keys.all?(String)

        raise Undecided.new(join(@prefix, path), "is #{Values.preview(value)}, not an object with string keys")
      end

      # The value written under key inside the Hash at path. For maps whose keys
      # are the user's, such as a function's environment variables.
      def entry(path, key)
        container = object(path)
        return nil if container.nil?

        where = join(join(@prefix, path), key.to_s)
        value = container[key]
        return nil if value.nil? || Values.no_value?(value)
        raise Undecided.new(where, "is #{Values.preview(value)}, a dynamic value") if Values.intrinsic?(value)

        value
      end

      # The paths of the items of the list at path, as this reader reads them.
      # CloudFormation lets a list be written as one object when it holds one
      # item, as a policy's Statement often is, so an object at path counts as
      # a list of one. Absent: no paths.
      def item_paths(path)
        value = raw(path)
        return [] if value.nil?
        return value.each_index.map { |index| "#{path}[#{index}]" } if value.is_a?(Array)
        return [ path ] if value.is_a?(Hash)

        raise Undecided.new(full_path(path), "is #{Values.preview(value)}, neither a list nor an object")
      end

      private

      # The value at path as written, or nil when a container on the way is
      # missing. Each step reads a key, then the item of a list when the key
      # The value at path as written, or nil when a container on the way is
      # missing. Each step reads a key, then the item of a list when the key
      # is written with "[n]". When a step meets an intrinsic function, :raise
      # ends the read as undecided, and :keep returns the intrinsic as it is
      # written, AWS::NoValue included.
      def walk(path, dynamic:)
        value = @root
        where = @prefix
        path.split(".").each do |part|
          match = SEGMENT.match(part)
          raise Undecided.new(full_path(path), "is not a path a reader understands") unless match

          where = join(where, match[1])
          value = read(value, match[1], where, dynamic, Hash)
          if match[2]
            where = "#{where}[#{match[2]}]"
            value = read(value, Integer(match[2], 10), where, dynamic, Array)
          end
        end
        value
      end

      # The item under key inside container, which must be of the given class.
      # AWS::NoValue reads as absent, except for :keep, which returns it.
      def read(container, key, where, dynamic, klass)
        return nil if container.nil?
        return nil unless container.is_a?(klass)

        value = container[key]
        return nil if Values.no_value?(value) && dynamic != :keep
        return Values.literal_sub_string(value) if Values.literal_sub?(value)
        if Values.intrinsic?(value)
          return value if dynamic == :keep

          raise Undecided.new(where, "is #{Values.preview(value)}, a dynamic value")
        end
        value
      end

      def join(prefix, path)
        return path if prefix.empty?
        return prefix if path.empty?

        "#{prefix}.#{path}"
      end
    end
  end
end
