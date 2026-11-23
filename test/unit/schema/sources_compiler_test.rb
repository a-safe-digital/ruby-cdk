# frozen_string_literal: true

require "test_helper"
require_relative "../../support/schema_fixtures"

# The compiler on the fixtures: how every shape of a provider schema becomes a kind, and how
# the resource specification is merged in. Sources::Compiler is the only way in.
class SourcesCompilerTest < Minitest::Test
  Sources = RubyCdk::Schema::Sources

  WIDGET = "AWS::Demo::Widget"
  UNLISTED = "AWS::Demo::Unlisted"
  ONLY_SPECIFICATION = "AWS::Demo::OnlySpec"

  # provider_schemas: { typeName => schema }. specification: the document as a Hash.
  def compile(provider_schemas: SchemaFixtures.provider_schemas, specification: SchemaFixtures.specification, region: "eu-west-1")
    document = Sources::ResourceSpecification.parse(JSON.generate(specification))
    Sources::Compiler.new(provider_schemas:, specification: document).call(region:)
  end

  def type(compiled, name)
    compiled.model["types"].fetch(name)
  end

  # The model's entry for a property: [kind, item kind, definition, update behaviour, unique items].
  def shape(compiled, name, property, definition = nil)
    body = definition ? type(compiled, name)["definitions"].fetch(definition) : type(compiled, name)
    entry = body["properties"].to_h.fetch(property)
    [ entry["kind"], entry["item"], entry["of"], entry["update"], entry["unique"] ]
  end

  def empty_specification
    { "PropertyTypes" => {}, "ResourceTypes" => {}, "ResourceSpecificationVersion" => "0.0.0" }
  end

  # One provider schema, no specification: what the provider schema says on its own.
  def alone(schema)
    compile(provider_schemas: { schema.fetch("typeName") => schema }, specification: empty_specification)
  end

  def test_the_model_names_its_format_its_region_and_the_version_of_the_specification
    compiled = compile

    assert_equal RubyCdk::Schema::MODEL_FORMAT, compiled.model["format"]
    assert_equal "eu-west-1", compiled.model["region"]
    assert_equal "1.2.3", compiled.model["specification_version"]
    assert_equal %w[AWS::Demo::OnlySpec AWS::Demo::Open AWS::Demo::Unlisted AWS::Demo::Widget], compiled.model["types"].keys.sort
    assert_equal({ "types" => 4, "provider_schemas" => 2, "resource_specification" => 3, "only_provider_schemas" => 1, "only_resource_specification" => 2 }, compiled.counts)
  end

  def test_scalars
    compiled = compile

    assert_equal [ "string", nil, nil, "immutable", nil ], shape(compiled, WIDGET, "Name")
    assert_equal [ "integer", nil, nil, "conditional", nil ], shape(compiled, WIDGET, "Size")
    assert_equal [ "long", nil, nil, "mutable", nil ], shape(compiled, WIDGET, "Offset")        # integer with format int64
    assert_equal [ "double", nil, nil, "mutable", nil ], shape(compiled, WIDGET, "Ratio")
    assert_equal [ "boolean", nil, nil, "mutable", nil ], shape(compiled, WIDGET, "Enabled")
    assert_equal [ "timestamp", nil, nil, "mutable", nil ], shape(compiled, WIDGET, "CreatedAt")  # string with format date-time
  end

  def test_a_reference_is_followed_to_what_it_actually_holds
    compiled = compile
    widget = type(compiled, WIDGET)

    assert_equal "^[a-z][a-z0-9-]*$", widget["properties"].to_h.fetch("Name")["pattern"]
    assert_equal %w[Low High], widget["properties"].to_h.fetch("Level")["values"]                  # a definition that is only an enum
    assert_equal "^(strict|lax)$", widget["properties"].to_h.fetch("Strictness")["pattern"]       # allOf around a reference
    assert_equal %w[Small Large], widget["properties"].to_h.fetch("Tier")["values"]               # a type next to a reference
    # The property says object and the definition says string: the definition wins.
    assert_equal [ "string", "^[a-z0-9.-]{3,63}$" ], widget["properties"].to_h.fetch("Bucket").values_at("kind", "pattern")
    assert_equal "string", shape(compiled, UNLISTED, "Token")[0]
  end

  def test_unions_accept_anything
    compiled = compile

    assert_equal "json", shape(compiled, WIDGET, "Policy")[0]          # type ["object", "string"]
    assert_equal "json", shape(compiled, WIDGET, "Manifest")[0]        # an empty schema
    assert_equal "json", shape(compiled, WIDGET, "Freeform")[0]        # an object with no properties
    assert_equal "json", shape(compiled, WIDGET, "Count")[0]           # anyOf: a string or an integer
    assert_equal "json", shape(compiled, WIDGET, "Parameters")[0]      # anyOf: an object with properties, or a map
  end

  def test_a_union_of_two_numeric_kinds_is_the_wider_one
    assert_equal "double", shape(compile, WIDGET, "Weight")[0]          # anyOf: an integer or a number
  end

  def test_an_enum_beside_an_open_alternative_leaves_the_choice_open
    entry = type(compile, WIDGET)["properties"].to_h.fetch("EngineType")

    assert_equal "string", entry["kind"]
    refute entry.key?("values"), "an enum next to a pattern accepts more than the enum"
    refute entry.key?("pattern"), "two alternatives accept different patterns"
  end

  def test_lists_and_maps_describe_their_elements
    compiled = compile

    assert_equal [ "list", "string", nil, "mutable", true ], shape(compiled, WIDGET, "Zones")       # uniqueItems
    assert_equal [ "list", "integer", nil, "mutable", true ], shape(compiled, WIDGET, "Sizes")     # the enum sits on the elements; unique from DuplicatesAllowed
    assert_equal [ 1, 2, 4 ], type(compiled, WIDGET)["properties"].to_h.fetch("Sizes")["values"]
    assert_equal [ "map", "string", nil, "mutable", nil ], shape(compiled, WIDGET, "Labels")       # patternProperties
    assert_equal [ "map", "nested", "ParameterConstraints", "mutable", nil ], shape(compiled, WIDGET, "Requests")  # an object whose elements are under items
    assert_equal [ "list", "nested", "Tag", "mutable", false ], shape(compiled, WIDGET, "Tags")
    assert_equal [ "list", "list", nil, "mutable", nil ], shape(compiled, WIDGET, "Matrix")        # a list of lists
  end

  def test_objects_with_named_properties_become_definitions
    compiled = compile
    widget = type(compiled, WIDGET)

    assert_equal [ "nested", nil, "Settings", "mutable", nil ], shape(compiled, WIDGET, "Settings")
    named_by_provider = %w[Level Strictness Tier BucketName ParameterConstraints Settings Tag S3Location Parameters ParameterMap Replica Status]
    assert_equal %w[InlineTags Route Settings.Window SpecNested Store], (widget["definitions"].keys - named_by_provider).sort
    refute widget["definitions"].key?("Unused"), "a definition nothing reaches is not written"

    # An object written inline under a property takes the property's name.
    assert_equal %w[Key Value], widget["definitions"].fetch("InlineTags")["properties"].map(&:first)
    assert_equal %w[Key], widget["definitions"].fetch("InlineTags")["required"]
    # The alternatives of a oneOf each name a property: the definition lists them all and requires none.
    route = widget["definitions"].fetch("Route")
    assert_equal %w[S3 Url], route["properties"].map(&:first)
    assert_equal [], route["required"]
    assert_equal "S3Location", route["properties"].to_h.fetch("S3")["of"]
    # A required-only alternative adds nothing; what the object itself requires stands.
    store = widget["definitions"].fetch("Store")
    assert_equal %w[Type Table], store["properties"].map(&:first)
    assert_equal %w[Type], store["required"]
    # An object inside a definition is named under that definition.
    assert_equal %w[From To], widget["definitions"].fetch("Settings.Window")["properties"].map(&:first)
  end

  def test_the_specification_contributes_the_update_behaviour
    compiled = compile

    assert_equal "immutable", shape(compiled, WIDGET, "Name")[3]                    # createOnlyProperties
    assert_equal "immutable", shape(compiled, WIDGET, "ApiKey", "Settings")[3]     # a nested create-only path
    assert_equal "conditional", shape(compiled, WIDGET, "Size")[3]                 # UpdateType Conditional
    assert_equal "conditional", shape(compiled, WIDGET, "Window", "Settings")[3]
    assert_equal "immutable", shape(compiled, WIDGET, "To", "Settings.Window")[3]  # two levels down, by name
    assert_equal "mutable", shape(compiled, WIDGET, "Retries", "Settings")[3]
    assert_equal "conditional", shape(compiled, WIDGET, "Code", "Status")[3]
    assert_equal "immutable", shape(compiled, WIDGET, "Priority", "Replica")[3]    # through a list's elements
    assert_equal "mutable", shape(compiled, WIDGET, "Key", "Tag")[3]              # the Tag every type shares
    # The provider's conditionalCreateOnlyProperties gives way to the specification's UpdateType.
    assert_equal "mutable", shape(compiled, WIDGET, "Durable")[3]
  end

  def test_a_read_only_property_has_no_update_behaviour
    compiled = compile

    refute type(compiled, WIDGET)["properties"].to_h.fetch("Arn").key?("update")
    refute type(compiled, WIDGET)["definitions"].fetch("Status")["properties"].to_h.fetch("Message").key?("update")
    assert_equal "conditional", shape(compiled, WIDGET, "Code", "Status")[3]
  end

  def test_the_provider_schema_decides_when_the_specification_says_nothing
    compiled = compile

    assert_equal "mutable", shape(compiled, WIDGET, "S3", "Route")[3]                 # nothing states it: writable, so mutable
    assert_equal "conditional", shape(compiled, UNLISTED, "Mode", "Options")[3]      # conditionalCreateOnlyProperties, type absent from the specification
    assert_equal "mutable", shape(compiled, UNLISTED, "Depth", "Options")[3]
    assert_equal %w[Fast Slow], type(compiled, UNLISTED)["definitions"].fetch("Options")["properties"].to_h.fetch("Mode")["values"]
  end

  def test_required_create_only_and_read_only
    widget = type(compile, WIDGET)
    unlisted = type(compile, UNLISTED)

    assert_equal %w[Name Settings], widget["required"]
    assert_equal %w[ImmutableBySpec Name Settings.ApiKey], widget["create_only"]   # the provider's paths and what the specification marks Immutable
    assert_equal %w[Arn Endpoint Status.Message], widget["read_only"]              # the provider's paths and the specification's Attributes
    assert_equal [ "Token" ], unlisted["create_only"]
    assert_equal [], unlisted["read_only"]
  end

  def test_properties_only_the_specification_knows_are_added_last
    compiled = compile
    widget = type(compiled, WIDGET)
    names = widget["properties"].map(&:first)

    assert_equal %w[SpecOnly ImmutableBySpec], names.last(2)
    assert_equal [ "list", "nested", "SpecNested", "conditional", true ], shape(compiled, WIDGET, "SpecOnly")
    assert_equal [ "string", nil, nil, "mutable", nil ], shape(compiled, WIDGET, "Alias", "SpecNested")
    assert_equal %w[Alias], widget["definitions"].fetch("SpecNested")["required"]
  end

  def test_properties_keep_the_provider_s_order
    names = type(compile, WIDGET)["properties"].map(&:first)

    assert_equal %w[Name Arn Size Offset Ratio Enabled CreatedAt Level], names.first(8)
    assert_equal names.last(2), %w[SpecOnly ImmutableBySpec]
  end

  def test_documentation_links
    compiled = compile

    assert_equal "https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-demo-widget.html", type(compiled, WIDGET)["documentation_url"]
    assert_equal "https://example.invalid/aws-demo-unlisted", type(compiled, UNLISTED)["documentation_url"]
  end

  def test_a_type_the_provider_schema_describes_alone
    compiled = alone("typeName" => "AWS::Demo::Bare", "properties" => { "Token" => { "type" => "string" } })

    assert_equal "provider", type(compiled, "AWS::Demo::Bare")["source"]
    assert_nil type(compiled, "AWS::Demo::Bare")["documentation_url"]
    assert_equal [], type(compiled, "AWS::Demo::Bare")["required"]
    assert_equal "mutable", shape(compiled, "AWS::Demo::Bare", "Token")[3]
  end

  def test_a_type_only_the_specification_describes
    compiled = compile
    only = type(compiled, ONLY_SPECIFICATION)

    assert_equal "specification", only["source"]
    assert_equal "https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-demo-onlyspec.html", only["documentation_url"]
    assert_equal %w[Name], only["required"]
    assert_equal %w[Name], only["create_only"]                 # what the specification marks Immutable
    assert_equal %w[Arn], only["read_only"]                    # its Attributes
    assert_equal [ "string", nil, nil, "immutable", nil ], shape(compiled, ONLY_SPECIFICATION, "Name")
    assert_equal [ "integer", nil, nil, "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "Port")
    assert_equal [ "long", nil, nil, "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "Big")
    assert_equal [ "double", nil, nil, "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "Ratio")
    assert_equal [ "boolean", nil, nil, "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "On")
    assert_equal [ "json", nil, nil, "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "Doc")
    assert_equal [ "nested", nil, "Sub", "conditional", nil ], shape(compiled, ONLY_SPECIFICATION, "Sub")
    assert_equal [ "list", "nested", "Sub", "mutable", true ], shape(compiled, ONLY_SPECIFICATION, "Many")      # DuplicatesAllowed false
    assert_equal [ "map", "nested", "Sub", "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "ByName")
    assert_equal [ "map", "string", nil, "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "Labels")
    assert_equal [ "list", "nested", "Sub", "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "Admins")    # a property type that is itself a list
    assert_equal [ "list", "nested", "Tag", "mutable", false ], shape(compiled, ONLY_SPECIFICATION, "Tags")    # the Tag every type shares
    assert_equal [ "json", nil, nil, "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "Nowhere")          # a name the specification does not define
    assert_equal [ "list", "json", nil, "mutable", false ], shape(compiled, ONLY_SPECIFICATION, "Loose")      # a list of an undefined type
    assert_equal [ "list", "list", nil, "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "Rows")         # a list of a type that is itself a list
    assert_equal [ "json", nil, nil, "mutable", nil ], shape(compiled, ONLY_SPECIFICATION, "Shapeless")      # neither a primitive nor a type
    assert_equal %w[Sub Tag], only["definitions"].keys.sort
    assert_equal %w[Id], only["definitions"].fetch("Sub")["required"]
    assert_equal "immutable", shape(compiled, ONLY_SPECIFICATION, "Rank", "Sub")[3]
  end

  def test_a_type_that_takes_any_property
    compiled = compile

    assert type(compiled, "AWS::Demo::Open")["additional_properties"]
    refute type(compiled, WIDGET).key?("additional_properties")
  end

  def test_the_same_sources_give_the_same_model_whatever_order_they_arrive_in
    sorted = JSON::State.new(sort_keys: true)
    first = compile
    second = compile
    third = compile(provider_schemas: SchemaFixtures.provider_schemas.to_a.reverse.to_h)

    assert_equal JSON.generate(first.model, sorted), JSON.generate(second.model, sorted)
    assert_equal JSON.generate(first.model, sorted), JSON.generate(third.model, sorted)
  end

  def test_a_reference_to_nothing_fails_loudly
    schema = { "typeName" => "AWS::Demo::Broken", "properties" => { "A" => { "$ref" => "#/definitions/Missing" } } }

    error = assert_raises(RubyCdk::Error) { alone(schema) }

    assert_match(/AWS::Demo::Broken: #\/definitions\/Missing points at nothing/, error.message)
  end

  def test_an_inline_object_may_not_take_the_name_of_a_different_definition
    inline = { "type" => "array", "items" => { "type" => "object", "properties" => { "Key" => { "type" => "string" } } } }
    definition = { "type" => "object", "properties" => { "Key" => { "type" => "string" }, "Value" => { "type" => "string" } } }
    schema = {
      "typeName" => "AWS::Demo::Clash",
      "properties" => { "Tags" => inline, "Other" => { "$ref" => "#/definitions/Tags" } },
      "definitions" => { "Tags" => definition }
    }

    error = assert_raises(RubyCdk::Error) { alone(schema) }

    assert_match(/AWS::Demo::Clash: the provider schema has a definition called Tags/, error.message)
  end

  def test_a_definition_that_refers_to_itself_is_written_once
    node = { "type" => "object", "properties" => { "Value" => { "type" => "string" }, "Next" => { "$ref" => "#/definitions/Node" } } }
    schema = { "typeName" => "AWS::Demo::Chain", "properties" => { "Head" => { "$ref" => "#/definitions/Node" } }, "definitions" => { "Node" => node } }
    compiled = alone(schema)

    assert_equal %w[Node], type(compiled, "AWS::Demo::Chain")["definitions"].keys
    assert_equal "Node", shape(compiled, "AWS::Demo::Chain", "Next", "Node")[2]
  end

  # How oneOf, anyOf and allOf are read. The real sources reach every one of these branches;
  # this pins what each gives.
  def test_composition_of_terms
    base = { "type" => "object", "properties" => { "Name" => { "type" => "string" } }, "required" => [ "Name" ] }
    strings = { "type" => "array", "items" => { "type" => "string" } }
    algebra = "AWS::Demo::Algebra"
    compiled = alone(
      "typeName" => algebra,
      "properties" => {
        "Choice" => { "oneOf" => [
          { "type" => "object", "properties" => { "A" => { "type" => "string" }, "Shared" => { "type" => "string" } }, "required" => [ "A" ] },
          { "type" => "object", "properties" => { "B" => { "type" => "integer" }, "Shared" => { "type" => "string" } }, "required" => [ "B" ] }
        ] },
        "Both" => { "allOf" => [
          { "type" => "object", "properties" => { "C" => { "type" => "string" } }, "required" => [ "C" ] },
          { "type" => "object", "properties" => { "D" => { "type" => "integer" } }, "required" => [ "D" ] }
        ] },
        "Plain" => { "$ref" => "#/definitions/Base" },
        "Wider" => { "anyOf" => [ { "$ref" => "#/definitions/Base" }, { "type" => "object", "properties" => { "Extra" => { "type" => "string" } } } ] },
        "Sets" => { "anyOf" => [
          { "type" => "array", "items" => { "type" => "object", "properties" => { "X" => { "type" => "string" } } } },
          { "type" => "array", "items" => { "type" => "object", "properties" => { "Y" => { "type" => "integer" } } } }
        ] },
        "SameTwice" => { "anyOf" => [ strings.merge("uniqueItems" => true), strings ] },
        "OtherList" => { "anyOf" => [ { "type" => "array", "items" => { "$ref" => "#/definitions/Base" } }, strings ] },
        "BothLists" => { "allOf" => [ strings, { "type" => "array", "items" => { "type" => "integer" } } ] },
        "WiderNumbers" => { "anyOf" => [ { "type" => "array", "items" => { "type" => "integer" } }, { "type" => "array", "items" => { "type" => "number" } } ] },
        "NarrowerNumbers" => { "allOf" => [ { "type" => "array", "items" => { "type" => "number" } }, { "type" => "array", "items" => { "type" => "integer" } } ] },
        "UntypedMap" => { "patternProperties" => { ".+" => { "type" => "string" } } },
        "UntypedList" => { "items" => { "type" => "string" } },
        "UntypedObject" => { "properties" => { "E" => { "type" => "string" } } },
        "UntypedTime" => { "format" => "date-time" },
        "Bare" => { "type" => "object" },
        # AWS::DynamoDB::Table KeySchema is written exactly like this.
        "ListOrObject" => { "oneOf" => [ { "type" => "array", "uniqueItems" => true, "items" => { "$ref" => "#/definitions/Base" } }, { "type" => "object" } ] },
        "MapOrObject" => { "anyOf" => [ { "type" => "object", "patternProperties" => { ".+" => { "type" => "string" } } }, { "type" => "object" } ] },
        "StringOrObject" => { "type" => "string", "oneOf" => [ { "type" => "string" }, { "type" => "object" } ] },
        "ObjectOrList" => { "anyOf" => [ { "type" => "object" }, { "type" => "array", "items" => { "type" => "string" } } ] },
        "BothShapes" => { "allOf" => [ { "$ref" => "#/definitions/Base" }, { "type" => "object", "properties" => { "More" => { "type" => "string" } }, "required" => [ "More" ] } ] },
        "ObjectOfBase" => { "type" => "object", "allOf" => [ { "$ref" => "#/definitions/Base" } ] },
        "Twice" => { "oneOf" => [
          { "type" => "object", "properties" => { "Inside" => { "$ref" => "#/definitions/Base" } }, "required" => [ "Inside" ] },
          { "type" => "object", "properties" => { "Inside" => { "$ref" => "#/definitions/Other" } }, "required" => [ "Inside" ] }
        ] }
      },
      "definitions" => {
        "Base" => base,
        "Other" => { "type" => "object", "properties" => { "Other" => { "type" => "integer" } } }
      }
    )
    definitions = type(compiled, algebra)["definitions"]

    # One of two objects: every property, and only what both require.
    assert_equal %w[A B Shared], definitions.fetch("Choice")["properties"].map(&:first).sort
    assert_equal [], definitions.fetch("Choice")["required"]
    # Both of two objects: every property, and both requirements.
    assert_equal %w[C D], definitions.fetch("Both")["properties"].map(&:first).sort
    assert_equal %w[C D], definitions.fetch("Both")["required"]
    # A definition keeps its name when it is reached on its own, and takes the property's when an alternative widens it.
    assert_equal "Base", shape(compiled, algebra, "Plain")[2]
    assert_equal %w[Name], definitions.fetch("Base")["required"]
    assert_equal "Wider", shape(compiled, algebra, "Wider")[2]
    assert_equal %w[Extra Name], definitions.fetch("Wider")["properties"].map(&:first).sort
    assert_equal [], definitions.fetch("Wider")["required"]
    # Two lists of two inline objects: one definition holding both sets of properties.
    assert_equal [ "list", "nested", "Sets", "mutable", nil ], shape(compiled, algebra, "Sets")
    assert_equal %w[X Y], definitions.fetch("Sets")["properties"].map(&:first).sort
    assert_equal [], definitions.fetch("Sets")["required"]
    # Lists: a rule one alternative states alone is no rule; two lists of different things are anything.
    assert_equal [ "list", "string", nil, "mutable", nil ], shape(compiled, algebra, "SameTwice")
    assert_equal "json", shape(compiled, algebra, "OtherList")[0]
    assert_equal "json", shape(compiled, algebra, "BothLists")[0]
    assert_equal [ "list", "double", nil, "mutable", nil ], shape(compiled, algebra, "WiderNumbers")        # an integer or a number
    assert_equal [ "list", "integer", nil, "mutable", nil ], shape(compiled, algebra, "NarrowerNumbers")  # a number that is an integer
    # Nodes that say what they hold without naming a type.
    assert_equal [ "map", "string", nil, "mutable", nil ], shape(compiled, algebra, "UntypedMap")
    assert_equal [ "list", "string", nil, "mutable", nil ], shape(compiled, algebra, "UntypedList")
    assert_equal [ "nested", nil, "UntypedObject", "mutable", nil ], shape(compiled, algebra, "UntypedObject")
    assert_equal [ "timestamp", nil, nil, "mutable", nil ], shape(compiled, algebra, "UntypedTime")
    assert_equal "json", shape(compiled, algebra, "Bare")[0]
    # A bare object gives way to what stands next to it, whichever comes first; a scalar next to one is anything.
    assert_equal [ "list", "nested", "Base", "mutable", true ], shape(compiled, algebra, "ListOrObject")
    assert_equal [ "map", "string", nil, "mutable", nil ], shape(compiled, algebra, "MapOrObject")
    assert_equal [ "list", "string", nil, "mutable", nil ], shape(compiled, algebra, "ObjectOrList")
    assert_equal "json", shape(compiled, algebra, "StringOrObject")[0]
    assert_equal [ "nested", nil, "Base", "mutable", nil ], shape(compiled, algebra, "ObjectOfBase")
    # Both of two definitions: one definition under the property's name, with everything both require.
    assert_equal [ "nested", nil, "BothShapes", "mutable", nil ], shape(compiled, algebra, "BothShapes")
    assert_equal %w[More Name], definitions.fetch("BothShapes")["properties"].map(&:first).sort
    assert_equal %w[More Name], definitions.fetch("BothShapes")["required"]
    # The same slot described by two different definitions: nothing precise can be said of it.
    assert_equal [ "nested", nil, "Twice", "mutable", nil ], shape(compiled, algebra, "Twice")
    assert_equal [ "json", nil, nil, "mutable", nil ], shape(compiled, algebra, "Inside", "Twice")
    assert_equal %w[Inside], definitions.fetch("Twice")["required"]
  end

  def test_a_primitive_type_this_version_does_not_know_fails_loudly
    specification = SchemaFixtures.specification
    specification["ResourceTypes"]["AWS::Demo::OnlySpec"]["Properties"]["Port"]["PrimitiveType"] = "Quaternion"

    error = assert_raises(RubyCdk::Error) { compile(specification:) }

    assert_match(/primitive type "Quaternion"/, error.message)
  end

  def test_an_update_type_this_version_does_not_know_fails_loudly
    specification = SchemaFixtures.specification
    specification["ResourceTypes"]["AWS::Demo::OnlySpec"]["Properties"]["Port"]["UpdateType"] = "Eventually"

    error = assert_raises(RubyCdk::Error) { compile(specification:) }

    assert_match(/AWS::Demo::OnlySpec: the specification gives a property the update type "Eventually"/, error.message)
  end
end
