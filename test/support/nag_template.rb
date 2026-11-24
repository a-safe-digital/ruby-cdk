# frozen_string_literal: true

require "json"
require "yaml"

# Reads a CloudFormation template written in YAML or in JSON into the plain
# Hash the rule pack takes (test/unit/nag/cfn_nag_fixtures_test.rb).
#
# Ported from cfn-model 0.6.6 (stelligent/cfn-model, commit
# 3ca846093639c1bfdf2069d33c8050ad66122e6b, MIT, Copyright (c) 2016-2020
# Stelligent), lib/cfn-model/parser/cfn_parser.rb: the short forms of the
# intrinsic functions (!Ref, !GetAtt, !Sub, !If, ...) are turned into the
# long-form Hashes of CloudFormation's JSON, which is how cfn-nag reads a
# template.
#
# What changed: cfn-model then gives every condition the value true and
# resolves Fn::If through its first branch, and follows a Ref to a parameter.
# None of that is done here, because the rule pack does none of it: to it an
# Fn::If and a Ref are dynamic values. The short forms Condition, Equals, Cidr,
# Transform, ToJsonString and Length are turned as well: CloudFormation accepts
# them, cfn-model's list does not name them. A plain scalar that starts with a
# colon, such as the CIDR block ::/0, stays a String: Psych would read it as a
# Symbol, and cfn-nag has to undo that by hand (ip_addr.rb).
module NagTemplate
  # The short form that is not an Fn:: function: !Ref X and !Condition C.
  REF = "Ref"
  CONDITION = "Condition"
  GET_ATT = "GetAtt"

  class << self
    # The template in the file at path: JSON as it is, YAML through read_yaml.
    def load(path)
      File.extname(path) == ".json" ? JSON.parse(File.read(path)) : read_yaml(File.read(path))
    end

    def read_yaml(text)
      Reader.new.read(text)
    end
  end

  # A Psych visitor that keeps the tags the default one drops: to Psych alone
  # !Ref X is the String "X" and !Sub [ ... ] a bare list, which a rule would
  # read as literals.
  class Reader < Psych::Visitors::ToRuby
    # Restricted: a fixture can hold no tag that builds an object of a class.
    # Date is allowed, by name as Psych's safe_load passes it, because an
    # unquoted "Version: 2012-10-17" in a policy document is a date to YAML;
    # no rule reads the version.
    CLASS_LOADER = Psych::ClassLoader::Restricted.new([ "Date" ], [])

    def initialize
      # parse_symbols false: "::/0" is a String.
      super(Psych::ScalarScanner.new(CLASS_LOADER, parse_symbols: false), CLASS_LOADER)
    end

    def read(text)
      accept(Psych.parse(text))
    end

    def visit_Psych_Nodes_Scalar(o)
      name = short_form(o.tag)
      return long_form(name, value_of(o)) if name

      super
    end

    def visit_Psych_Nodes_Sequence(o)
      wrapped(o) { super }
    end

    def visit_Psych_Nodes_Mapping(o)
      wrapped(o) { super }
    end

    private

    # The name of a short-form tag ("Ref" for "!Ref"), or nil for any other tag.
    def short_form(tag)
      return nil unless tag.is_a?(String) && tag.start_with?("!") && !tag.start_with?("!!")

      tag[1..]
    end

    # What the tagged scalar says, read as if it had no tag.
    def value_of(o)
      visit_Psych_Nodes_Scalar(Psych::Nodes::Scalar.new(o.value, o.anchor, nil, o.plain, o.quoted, o.style))
    end

    def wrapped(o)
      value = yield
      name = short_form(o.tag)
      name ? long_form(name, value) : value
    end

    def long_form(name, value)
      case name
      when REF
        { REF => value }
      when CONDITION
        { CONDITION => value }
      when GET_ATT
        { "Fn::#{GET_ATT}" => value.is_a?(String) ? value.split(".") : value }
      else
        { "Fn::#{name}" => value }
      end
    end
  end
end
