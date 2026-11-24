# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/core/test/stack.test.ts, in aws/aws-cdk
#   Commit:  622f51fa4999d5557c1d1da292c04cc186ac6818 (main, read on 2026-11-24)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 149 declarations: 146 test, 1 testDeprecated, 2 test.each.
# The table of line 58 expands to 15 cases, the one of line 1183 to 2, and the
# describe.each([false, true]) of line 2762 runs its 4 tests twice, so jest
# runs 168 cases, and that is what is counted here. Each ported one keeps its
# name, as a comment above the test, and what it expects. What changed to get
# there:
#
#   - The origin's `new Stack()` is `stack` here: a Stack of this tool needs an
#     App and an id, and its name is the id behind the app's
#     stack_name_prefix. There is no separate stackName prop and no artifact
#     id: the stack name is written, never generated (architecture §3).
#   - `Stack.of(x)` is Construct#stack, `Stack.isStack(x)` is
#     x.is_a?(RubyCdk::Stack), `stack.addTransform(name)` and
#     `templateOptions.transforms` are stack.transform(name),
#     `templateOptions.description` is the description: keyword, and
#     `stack.exportValue(value, { name })` plus its list form are export and
#     Fn.import_value (§9: the export and its import are written by hand).
#   - Every template below carries AWSTemplateFormatVersion 2010-09-09, which
#     the serialization contract writes here always and the CDK writes only
#     when templateOptions names one — the CDK's empty template is {} and its
#     synthesized corpus templates start at "Resources".
#     with_format_version marks it on every expectation the key adds to.
#   - An element's logical ID holds letters and digits only and is refused
#     where it is declared (in the tree since 796deb2). Every id the ported
#     cases declare is already letters and digits, so no expectation moved for
#     it; stack and construct ids may still hold "_" and "-".
#   - A logical ID is written, never hashed (D-004, D-029): where the CDK
#     asserts a derived or generated name, the port asserts the id the user
#     wrote.
#   - Retained types take RetainExceptOnCreate instead of Retain (D-007). None
#     of the ported cases holds one.
#
# Changed expectations, stated next to the test:
#
#   - a stack can be serialized into a CloudFormation template, initially
#     it's empty; stack objects have some template-level properties;
#     stack.templateOptions can be used to set template-level options: the
#     format version is pinned to 2010-09-09 here (§5, D-028), where the CDK
#     writes what templateOptions.templateFormatVersion says; and the
#     deprecated singular templateOptions.transform field and its warning have
#     no counterpart, so the Transform entry holds what transform() was given.
#   - stack name cannot exceed 128 characters; stack validation is performed
#     on explicit stack name. The name is the id here, and the 128-character
#     rule is rule V13: refused when the stack is synthesized, where the CDK
#     refuses at construction. The digit-leading id of the second case is what
#     makes a name the CDK refuses with an explicit stackName prop.
#   - Stack.getByPath can be used to find any CloudFormation element.
#     Declared elements are handles read off the Stack's named collections
#     (parameters, outputs, conditions), not children of the stack.
#   - addStackDependency handles duplicate dependency reasons. The CDK's
#     addStackDependency ties child stacks under a parent construct; here the
#     stacks sit in the App and add_dependency is the call, which keeps the
#     first declaration of a dependency.
#   - manual exports can also just be used to create an export of anything;
#     manual list exports ...; exports with name can include description;
#     list exports with name can include description; exports without name can
#     include description; list exports without name can include description.
#     The output keeps the id it was given, where the CDK names it
#     Export<name> or derives ExportsOutput... from the attribute, and the
#     export name is "#{stack_name}-#{id}" (§3, §9). The CDK's import of a
#     list export resolves to one Fn::Split; this tool's import of a known
#     length (Fn.import_list_value) writes one Fn::Select per element. A join
#     of one element collapses to that element when it is resolved here (the
#     ported 'resolves to the value if only one value is joined' in fn_test),
#     where the CDK keeps the Fn::Join because its element is a list token.
#   - Stack name is inherited from App name if available. The CDK derives
#     ProdStackD5279B22 from the construct path and hashes it; here the name
#     is the app's stack_name_prefix in front of the id (§3, D-004).
#   - Stack.of(stack) returns the correct stack; Stack.of() throws when there
#     is no parent Stack. Stack.of is Construct#stack; a construct above which
#     there is no Stack answers nil here, where the CDK raises — a resource
#     refuses at creation instead (a resource is created inside a Stack).
#   - stack tags are both in stack metadata and stack artifact properties (the
#     two runs of describe.each). The CDK reads the tags back from its cloud
#     assembly artifact; the manifest here carries no tags (§12) — the
#     deployer sends stack.tags with the change set (§9). The
#     EXPLICIT_STACK_TAGS flag does not exist here, and both runs hold the
#     same expectation.
#   - warning when stack tags contain tokens. The CDK warns ("Ignoring stack
#     tags that contain deploy-time values") and drops the tag; a tag value
#     here is a String or a Symbol, and the Lazy — the nearest thing to the
#     CDK's token — is refused when the stack is built.
#   - Termination Protection is reflected in Cloud Assembly artifact. The CDK
#     reads terminationProtection off the artifact; the manifest here carries
#     no per-stack flags (§12), and the attribute is what the deployer
#     reconciles before every deploy (§3, §9).
#   - region passed in stack environment must be a string. Refused here for
#     its shape rather than its type — the region must look like eu-west-1 —
#     where the CDK asks for a String (stack.ts:1523); a raise is what both do.
#   - indent templates when suppressTemplateIndentation is not set. The CDK
#     writes one space of indentation and no format version key; the
#     serialization contract here (§5, D-028) fixes two spaces and the key.
#   - stack adds template-producer metadata to the cloud assembly. The CDK
#     writes the file name as metadata of the stack artifact; the manifest
#     here names the template in the stack's entry (§12).
#   - Stack descriptions have a limited length. The CDK's test constructs the
#     stack and asserts nothing; its source refuses a description over 512
#     characters (stack.ts:500-506, StackDescriptionTooLong), and this tool
#     refuses one too, where the element is declared. The port asserts the
#     refusal, which is what the CDK's source does and its test never did.
#
# FINDING, ported and left failing:
#
#   - account id passed in stack environment must be a string. The CDK refuses
#     an account id that is not a String ("Account id of stack environment
#     must be a 'string' but received 'number'", core/lib/stack.ts:1519). This
#     tool accepts a 12-digit Integer and writes it as a string:
#     RubyCdk::Env.new(account: 111111111111, region: "us-east-1") answers an
#     Env of account "111111111111" and nothing raises.
#
# Not ported, with the reason:
#
#   Not ported because a later wave builds it:
#   - testDeprecated('Include should support non-hash top-level template
#     elements like "Description"'). CfnInclude is not built; Wave 2 ports the
#     cloudformation-include suites as fixtures of the validator (W2.8) and no
#     wave builds the construct.
#   - cross-stack references of nested stack lists returned from Fn::GetAtt
#     work; Nested Stacks are synthesized with DESTROY policy; asset metadata
#     added to NestedStack resource that contains asset path and property;
#     automatic cross-stack references and manual exports look the same:
#     nested stack edition; and the two runs of test.each(['up','down']) no
#     cross-stack reference flag warning when referencing %s across nested
#     stacks. Nested stacks, which this tool does not have before 0.1.0
#     (docs/07-testing.md §12).
#   - throw error if overrideLogicalId is used and logicalId is locked; do not
#     throw error if overrideLogicalId is used and logicalId is not locked;
#     overrideLogicalId(id) can be used to override the logical ID of a
#     resource. The override machinery; no wave names it before 0.1.0.
#   - metadata is collected at the stack boundary; Stacks log their own
#     creation stack trace. Construct annotations (node.addMetadata) and their
#     collection into the assembly; no wave names them before 0.1.0.
#   - stack tags are reflected in the stack cloud assembly artifact metadata;
#     stack tags are reflected in the stack artifact properties; and the two
#     runs each of tags added using Tags.of() are or are not applied to Stacks
#     and tags added using Tags.of() are applied to Stacks if explicitly
#     included. The Tags aspect (docs/07-testing.md §4); no wave names it
#     before 0.1.0.
#   - stack inside a Stage has a nested-assembly-relative template path in
#     template-producer metadata. Stages; no wave names them before 0.1.0.
#
#   Not ported because this tool differs by design:
#   - the 15 rows of test.each('valid stack artifact id for construct id').
#     An assembly artifact id does not exist here: the template file is named
#     after the stack name (architecture §12), and the name is the id behind
#     the app's prefix (§3).
#   - getter values involving tokens return the same value every invocation;
#     Cross-stack use of Region and account returns nonscoped intrinsic
#     because the two stacks must be in the same region anyway; urlSuffix does
#     not imply a stack dependency; stack.availabilityZones falls back to
#     Fn::GetAZ[0],[2] if region is not specified; stack with region supplied
#     via props returns literal value. There is no token encoding (D-003) and
#     the Stack contract names no region, account, partition or urlSuffix
#     accessor (§3); Fn.get_azs is there for direct use.
#   - when stackResourceLimit is default, should give error; when
#     stackResourceLimit is defined, should give the proper error; when
#     stackResourceLimit is 0, should not give error. No per-stack resource
#     limit: not in the binding contract (§3) nor in rules V1–V23; CloudFormation
#     refuses an over-limit template itself (§19, spike S2).
#   - Overriding `Stack._toCloudFormation` allows arbitrary post-processing of
#     the generated template during synthesis. There is no post-processing
#     hook; the phases of §5 run in their fixed order.
#   - Pseudo values attached to one stack can be referenced in another stack;
#     Cross-stack references are detected in resource properties; Cross-stack
#     export names account for stack name lengths; Cross-stack reference
#     export names are relative to the stack (when the flag is set);
#     cross-stack references in lazy tokens work; cross-stack references in
#     strings work; cross-stack references of lists returned from Fn::GetAtt
#     work; cross-stack references of lists returned from Fn::GetAtt can be
#     used with CFN intrinsics; cross-stack references of lists returned from
#     Fn::Ref work; CfnSynthesisError is ignored when preparing cross
#     references; cross stack references and dependencies work within child
#     stacks (non-nested); cross-stack dependencies can be queried with
#     _stackDependenciesCausedBy; addStackDependency adds one
#     StackDependencyReason with defaults; _removeAssemblyDependency removes
#     one StackDependencyReason of two from _stackDependencies;
#     _removeAssemblyDependency removes a StackDependency from
#     _stackDependencies with the last reason; automatic cross-stack
#     references and manual exports look the same; automatic cross-stack
#     references and manual list exports look the same; stacks know about
#     their dependencies; cross-stack reference (substack references parent
#     stack); cross-stack reference (parent stack references substack); Stacks
#     can be children of other stacks (substack) and they will be synthesized
#     separately; Stack.of() works for substacks; allows using the same stack
#     name for two stacks (i.e. in different regions). Automatic cross-stack
#     references are not generated here (architecture §9: nothing is generated
#     implicitly; D-003); the manual ones are export and export_name, ported
#     above; and a stack is created in an App, so none of the substack shapes
#     exists (§3). A stack name is derived from the unique id, so two stacks
#     cannot share one.
#   - manual exports require a name if not supplying a resource attribute;
#     manual list exports require a name if not supplying a resource
#     attribute. An export's name is always written here: export(id, ...) is
#     named by its id (§3, §9), and there is no derived name to require.
#   - cross-region stack references, crossRegionReferences=true; cross-region
#     stack references work without crossRegionReferences prop; cross region
#     stack references with multiple stacks, crossRegionReferences=true; cross
#     region stack references with multiple stacks and multiple regions,
#     crossRegionReferences=true; cross-region references default to strong
#     (ExportWriter/ExportReader) when flag is unset; cross-region strong
#     references use ExportWriter/ExportReader; cross-region both references
#     generate ExportWriter AND Fn::GetStackOutput; cross-region weak
#     references serialize STRING_LIST with Fn::Join and deserialize with
#     Fn::Split; per-resource weak override works for cross-region references;
#     cross-account strong references emit warning and use Fn::GetStackOutput;
#     cross-account references from multiple consumers share a single role
#     with multiple principals; cross-account references from a single
#     consumer produce a single principal string; cross-account references
#     with strong flag emit warning but still synth. No cross-region or
#     cross-account machinery: a stack deploys into its env (§13), and no
#     writer or reader custom resources exist.
#   - emits a single warning per app when cross-stack reference flag is unset;
#     no warning when cross-stack reference flag is explicitly set; emits
#     transitional warning when cross-stack reference flag is set to both;
#     invalid cross stack reference strength throws; per-resource weak
#     override uses Fn::GetStackOutput when global is strong (same region);
#     per-resource strong override uses Fn::ImportValue when global is weak
#     (same region); per-resource override only affects the overridden
#     resource; applyCrossStackReferenceStrength on CfnResource stores and
#     exposes value; CrossStackReferences.of().produce() delegates to
#     applyCrossStackReferenceStrength; CrossStackReferences.of().consume()
#     sets context on the scope; consumeReference weakens a single reference
#     usage (same region); consumeReference with explicit WEAK strength (same
#     region); consumeReference throws for non-reference values; same-region
#     weak references use Fn::GetStackOutput; same-region both references
#     generate Export AND Fn::GetStackOutput; same-region weak references
#     serialize STRING_LIST with Fn::Join and deserialize with Fn::Split;
#     same-region both references serialize STRING_LIST with Fn::Join for
#     publish output. No synthesis warnings or annotations
#     (docs/07-testing.md §4), no context flags, no reference strengths and no
#     Fn::GetStackOutput (§9).
#   - the four of describe('stack partition literal feature flag'): stacks
#     with no region defined; stacks with an unknown region; (disabled);
#     (enabled). No context or feature flags, no RegionInfo (§3; D-003).
#   - Stack name can be overridden via properties; stack construct id does not
#     go through stack name validation if there is an explicit stack name;
#     generated stack names will not exceed 128 characters. The name is the id
#     behind the app's prefix, written, never generated and never renamed
#     (§3, D-004); a name over 128 characters is refused by rule V13, not
#     truncated.
#   - stack notification arns defaults to undefined; stack notification arns
#     are reflected in the stack artifact properties; throws if stack
#     notification arns contain tokens. Notification ARNs are not in the Stack
#     contract (§3) nor in the deploy seam (§9).
#   - Set termination protection to true with setter; Set termination
#     protection to false with setter. The attribute is fixed when the stack
#     is built (§3 declares a reader); the deployer reconciles it.
#   - context can be set on a stack using a LegacySynthesizer; context can be
#     set on a stack using a DefaultSynthesizer; version reporting can be
#     configured on the app; version reporting can be configured with context;
#     version reporting can be configured on the stack. No synthesizer
#     objects, no context and no analytics reporting.
#   - requires bundling when wildcard is specified in BUNDLING_STACKS;
#     requires bundling when stackName has an exact match in
#     BUNDLING_STACKS; does not require bundling when no item from
#     BUILDING_STACKS matches stackName; does not require bundling when
#     BUNDLING_STACKS is empty. No bundling (§21: the user vendors gems).
#   - do not indent templates when suppressTemplateIndentation is true; do not
#     indent templates when @aws-cdk/core:suppressTemplateIndentation is true.
#     The bytes are fixed (§5, D-028); there is no suppression option.
#   - can specify a valid permissions boundary name; can specify a valid
#     permissions boundary arn; single aspect is added to stack; throws if
#     pseudo parameters are in the name. No permissions boundary (§3); two of
#     the four also need aspects and a Stage.
#   - the five of describe('regionalFact'): regional facts return a literal
#     value if possible; regional facts are simplified to use URL_SUFFIX token
#     if possible; regional facts are simplified to use concrete values if
#     URL_SUFFIX token is not necessary; regional facts use the global lookup
#     map if partition is the literal string of "undefined"; regional facts
#     generate a mapping if necessary. No region-info facts (§3; D-003).
#
# Parity: 168 cases in the origin; 36 ported; 132 not ported.

require "test_helper"
require "support/cdk_core"

class CdkCoreStackTest < CdkCore::TestCase
  # describe('stack')

  # test("a stack can be serialized into a CloudFormation template, initially it's empty")
  # Changed: the CDK's empty template is {}; the serialization contract (§5,
  # D-028) writes the format version on every template here.
  def test_a_stack_can_be_serialized_into_a_cloud_formation_template_initially_it_s_empty
    assert_equal({ "AWSTemplateFormatVersion" => "2010-09-09" }, stack.to_template)
  end

  # test('stack name cannot exceed 128 characters')
  # Changed: the name is the id here (§3) and the rule is V13, checked when
  # the stack is synthesized; the CDK refuses at construction with
  # "Stack name must be <= 128 characters."
  def test_stack_name_cannot_exceed_128_characters
    long = "LookAtMyReallyLongStackNameThisStackNameIsLongerThan128CharactersThatIsNuts" \
      "IDontThinkThereIsEnoughAWSAvailableToLetEveryoneHaveStackNamesThisLong"
    app = build_app

    error = assert_raises(RubyCdk::ValidationError) { RubyCdk::Stack.new(app, long).to_template }

    assert_match(/at most 128 characters/, error.message)
  end

  # test('stack objects have some template-level properties, such as Description, Version, Transform')
  # Changed: the version is pinned (§5, D-028); description is the
  # description: keyword and the transform is stack.transform.
  def test_stack_objects_have_some_template_level_properties_such_as_description_version_transform
    stack = stack(description: "This is my description") { transform("SAMy") }

    assert_equal(with_format_version(
      "Description" => "This is my description",
      "Transform" => "SAMy"
    ), stack.to_template)
  end

  # test('Stack.isStack indicates that a construct is a stack')
  def test_stack_is_stack_indicates_that_a_construct_is_a_stack
    built = stack
    construct = RubyCdk::Construct.new(built, "Construct")

    assert built.is_a?(RubyCdk::Stack)
    refute construct.is_a?(RubyCdk::Stack)
  end

  # test('stack.id is not included in the logical identities of resources within it')
  def test_stack_id_is_not_included_in_the_logical_identities_of_resources_within_it
    stack = stack { resource("MyResource", "MyResourceType") }

    assert_equal(with_format_version(
      "Resources" => { "MyResource" => { "Type" => "MyResourceType" } }
    ), stack.to_template)
  end

  # test('stack.templateOptions can be used to set template-level options')
  # Changed: the version is pinned (§5, D-028), and the deprecated singular
  # templateOptions.transform and its warning have no counterpart, so
  # Transform holds what transform() was given — the CDK writes
  # ['Transform', 'DeprecatedField'].
  def test_stack_template_options_can_be_used_to_set_template_level_options
    stack = stack(description: "StackDescription") do
      transform("Transform")
      add_metadata("MetadataKey", "MetadataValue")
    end

    assert_equal(with_format_version(
      "Description" => "StackDescription",
      "Transform" => "Transform",
      "Metadata" => { "MetadataKey" => "MetadataValue" }
    ), stack.to_template)
  end

  # test('stack.templateOptions.transforms removes duplicate values')
  def test_stack_template_options_transforms_removes_duplicate_values
    stack = stack { transform("A"); transform("B"); transform("C"); transform("A") }

    assert_equal(with_format_version(
      "Transform" => %w[ A B C ]
    ), stack.to_template)
  end

  # test('stack.addTransform() adds a transform')
  def test_stack_add_transform_adds_a_transform
    stack = stack { transform("A"); transform("B"); transform("C") }

    assert_equal(with_format_version(
      "Transform" => %w[ A B C ]
    ), stack.to_template)
  end

  # test('Stack.getByPath can be used to find any CloudFormation element (Parameter, Output, etc)')
  # Changed: declared elements are handles read off the Stack's named
  # collections, not children of the stack.
  def test_stack_get_by_path_can_be_used_to_find_any_cloud_formation_element_parameter_output_etc
    stack = stack do
      parameter("MyParam", type: "String")
      output("MyOutput", value: "boom")
      condition("MyCondition", Fn.equals("a", "a"))
    end

    assert_equal "MyParam", stack.parameters["MyParam"].name
    assert_equal "boom", stack.outputs["MyOutput"].value
    assert_equal({ "Fn::Equals" => [ "a", "a" ] }, stack.conditions["MyCondition"].fn)
  end

  # test('Stack names can have hyphens in them')
  def test_stack_names_can_have_hyphens_in_them
    app = build_app

    stack = RubyCdk::Stack.new(app, "Hello-World")

    assert_equal "Hello-World", stack.stack_name
  end

  # test('Stacks can have a description given to them')
  def test_stacks_can_have_a_description_given_to_them
    stack = stack(description: "My stack, hands off!")

    assert_equal(with_format_version(
      "Description" => "My stack, hands off!"
    ), stack.to_template)
  end

  # test('Stack descriptions have a limited length')
  # The CDK's test constructs the stack and asserts nothing; its source refuses
  # a description over 512 characters (stack.ts:500-506, StackDescriptionTooLong),
  # and this tool refuses one too, where the element is declared. The CDK's
  # description: prop is the description: keyword here.
  def test_stack_descriptions_have_a_limited_length
    description = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor " \
      "incididunt ut labore et dolore magna aliqua. " * 28

    assert_operator description.length, :>, 512
    error = assert_raises(RubyCdk::UsageError) { stack(description: description) }

    assert_match(/at most 512/, error.message)
    assert_match(/StackDescriptionTooLong/, error.message)
  end

  # test('addStackDependency handles duplicate dependency reasons')
  # Changed: the CDK's addStackDependency ties child stacks under a parent
  # construct; here the stacks sit in the App and add_dependency is the call.
  def test_add_stack_dependency_handles_duplicate_dependency_reasons
    app = build_app
    first = RubyCdk::Stack.new(app, "First")
    second = RubyCdk::Stack.new(app, "Second")
    last = RubyCdk::Stack.new(app, "Last") { add_dependency(first) }

    last.add_dependency(second)
    before = last.dependencies
    last.add_dependency(first)

    assert_equal before, last.dependencies
    assert_equal [ first, second ], last.dependencies
  end

  # test('manual exports can also just be used to create an export of anything')
  # Changed: the CDK names the output ExportMyExport and exports the bare name
  # MyExport; here the output keeps its id and the export name is
  # "#{stack_name}-#{id}" (§3, §9).
  def test_manual_exports_can_also_just_be_used_to_create_an_export_of_anything
    stack = stack { export("MyExport", value: "someValue") }

    assert_equal({ "Fn::ImportValue" => "Stack-MyExport" }, stack.resolve(Fn.import_value(stack.export_name("MyExport"))))
    assert_equal(with_format_version(
      "Outputs" => {
        "MyExport" => { "Value" => "someValue", "Export" => { "Name" => "Stack-MyExport" } }
      }
    ), stack.to_template)
  end

  # test('manual list exports can also just be used to create an export of anything')
  # Changed: output and export names as above; and the CDK's
  # exportStringListValue resolves to one Fn::Split, where this tool's import
  # of a known length (Fn.import_list_value) writes one Fn::Select per
  # element.
  def test_manual_list_exports_can_also_just_be_used_to_create_an_export_of_anything
    stack = stack { export("MyExport", value: Fn.join("||", %w[ someValue anotherValue ])) }

    imported = { "Fn::Split" => [ "||", { "Fn::ImportValue" => "Stack-MyExport" } ] }
    assert_equal(with_format_version(
      "Outputs" => {
        "MyExport" => { "Value" => "someValue||anotherValue", "Export" => { "Name" => "Stack-MyExport" } }
      }
    ), stack.to_template)
    assert_equal [
      { "Fn::Select" => [ 0, imported ] },
      { "Fn::Select" => [ 1, imported ] }
    ], stack.resolve(Fn.import_list_value(stack.export_name("MyExport"), 2, "||"))
  end

  # test('exports with name can include description')
  # Changed: output and export names as in the manual-exports cases above.
  def test_exports_with_name_can_include_description
    stack = stack { export("MyExport", value: "someValue", description: "This is a description") }

    assert_equal(with_format_version(
      "Outputs" => {
        "MyExport" => {
          "Value" => "someValue", "Description" => "This is a description", "Export" => { "Name" => "Stack-MyExport" }
        }
      }
    ), stack.to_template)
  end

  # test('list exports with name can include description')
  # Changed: output and export names as in the manual-exports cases above.
  def test_list_exports_with_name_can_include_description
    stack = stack do
      export("MyExport", value: Fn.join("||", %w[ someValue anotherValue ]), description: "This is a description")
    end

    assert_equal(with_format_version(
      "Outputs" => {
        "MyExport" => {
          "Value" => "someValue||anotherValue",
          "Description" => "This is a description",
          "Export" => { "Name" => "Stack-MyExport" }
        }
      }
    ), stack.to_template)
  end

  # test('exports without name can include description')
  # Changed: an export's name is always written here (the id), where the CDK
  # derives ExportsOutputFnGetAtt... from the attribute. The value and the
  # description are the CDK's.
  def test_exports_without_name_can_include_description
    stack = stack do
      @r = resource("Resource", "AWS::Resource")
      export("ExportedAtt", value: Fn.get_att(@r, "Att"), description: "This is a description")
    end

    assert_equal(with_format_version(
      "Resources" => { "Resource" => { "Type" => "AWS::Resource" } },
      "Outputs" => {
        "ExportedAtt" => {
          "Value" => { "Fn::GetAtt" => [ "Resource", "Att" ] },
          "Description" => "This is a description",
          "Export" => { "Name" => "Stack-ExportedAtt" }
        }
      }
    ), stack.to_template)
  end

  # test('list exports without name can include description')
  # Changed: the name is written (as above), and a join of one element
  # collapses to that element when it is resolved here (the ported 'resolves
  # to the value if only one value is joined' in fn_test), where the CDK keeps
  # the Fn::Join because its element is a list token.
  def test_list_exports_without_name_can_include_description
    stack = stack do
      @r = resource("Resource", "AWS::Resource")
      export("ExportedList", value: Fn.join("||", [ Fn.get_att(@r, "Att") ]), description: "This is a description")
    end

    assert_equal(with_format_version(
      "Resources" => { "Resource" => { "Type" => "AWS::Resource" } },
      "Outputs" => {
        "ExportedList" => {
          "Value" => { "Fn::GetAtt" => [ "Resource", "Att" ] },
          "Description" => "This is a description",
          "Export" => { "Name" => "Stack-ExportedList" }
        }
      }
    ), stack.to_template)
  end

  # test('Stack name is inherited from App name if available')
  # Changed: the CDK derives ProdStackD5279B22 from the construct path and
  # hashes it; here the name is the app's stack_name_prefix in front of the id
  # (§3, D-004).
  def test_stack_name_is_inherited_from_app_name_if_available
    app = build_app(stack_name_prefix: "Prod")

    assert_equal "ProdStack", RubyCdk::Stack.new(app, "Stack").stack_name
  end

  # test('stack validation is performed on explicit stack name')
  # Changed: there is no separate stackName prop, so the case is exercised
  # with an id whose name cannot be valid. Rule V13 refuses it at synthesis;
  # the CDK refuses at construction.
  def test_stack_validation_is_performed_on_explicit_stack_name
    app = build_app

    error = assert_raises(RubyCdk::ValidationError) { RubyCdk::Stack.new(app, "0startWithNumber").to_template }

    assert_match(/must start with a letter/, error.message)
  end

  # test('Stack.of(stack) returns the correct stack')
  # Stack.of is Construct#stack here.
  def test_stack_of_stack_returns_the_correct_stack
    built = stack
    parent = RubyCdk::Construct.new(built, "Parent")
    construct = RubyCdk::Construct.new(parent, "Construct")

    assert_same built, built.stack
    assert_same built, construct.stack
  end

  # test('Stack.of() throws when there is no parent Stack')
  # Changed: the CDK raises ("should be created in the scope of a Stack");
  # Construct#stack answers nil here, and a resource refuses at creation
  # instead.
  def test_stack_of_throws_when_there_is_no_parent_stack
    app = build_app
    loose = RubyCdk::Construct.new(app, "Loose")
    construct = RubyCdk::Construct.new(loose, "Construct")

    assert_nil construct.stack
    assert_raises(RubyCdk::UsageError) { loose.resource("Table", "AWS::SNS::Topic") }
  end

  # describe.each([false, true])('with EXPLICIT_STACK_TAGS set to %p'), run false
  # test('stack tags are both in stack metadata and stack artifact properties')
  # Changed: the CDK reads the tags back from its cloud assembly artifact; the
  # manifest here carries no tags (§12) — the deployer sends stack.tags with
  # the change set (§9). The flag itself does not exist here, and both runs
  # hold the same expectation.
  def test_with_explicit_stack_tags_set_to_false_stack_tags_are_both_in_stack_metadata_and_artifact_properties
    stack = build_stack("stack1", stack_options: { tags: { foo: "bar" } })

    assert_equal({ "foo" => "bar" }, stack.tags)
  end

  # describe.each([false, true])('with EXPLICIT_STACK_TAGS set to %p'), run true
  # test('stack tags are both in stack metadata and stack artifact properties')
  def test_with_explicit_stack_tags_set_to_true_stack_tags_are_both_in_stack_metadata_and_artifact_properties
    stack = build_stack("stack1", stack_options: { tags: { foo: "bar" } })

    assert_equal({ "foo" => "bar" }, stack.tags)
  end

  # describe.each([false, true])('with EXPLICIT_STACK_TAGS set to %p'), run false
  # test('stack tags do not appear in template')
  def test_with_explicit_stack_tags_set_to_false_stack_tags_do_not_appear_in_template
    stack = build_stack("stack1", stack_options: { tags: { foo: "bar" } }) do
      resource("res", "AWS::Taggable::Resource", properties: { "R" => 1 })
    end

    assert_equal(with_format_version(
      "Resources" => {
        "res" => { "Type" => "AWS::Taggable::Resource", "Properties" => { "R" => 1 } }
      }
    ), stack.to_template)
  end

  # describe.each([false, true])('with EXPLICIT_STACK_TAGS set to %p'), run true
  # test('stack tags do not appear in template')
  def test_with_explicit_stack_tags_set_to_true_stack_tags_do_not_appear_in_template
    stack = build_stack("stack1", stack_options: { tags: { foo: "bar" } }) do
      resource("res", "AWS::Taggable::Resource", properties: { "R" => 1 })
    end

    assert_equal(with_format_version(
      "Resources" => {
        "res" => { "Type" => "AWS::Taggable::Resource", "Properties" => { "R" => 1 } }
      }
    ), stack.to_template)
  end

  # test('warning when stack tags contain tokens')
  # Changed: the CDK warns ("Ignoring stack tags that contain deploy-time
  # values") and drops the tag; a tag value here is a String or a Symbol, and
  # the Lazy — the nearest thing to the CDK's token — is refused when the
  # stack is built.
  def test_warning_when_stack_tags_contain_tokens
    error = assert_raises(RubyCdk::UsageError) do
      build_stack("stack1", stack_options: { tags: { foo: Lazy.new { "lazy" } } })
    end

    assert_match(/tag value/, error.message)
  end

  # test('Termination Protection is reflected in Cloud Assembly artifact')
  # Changed: the CDK reads terminationProtection off the artifact; the
  # manifest here carries no per-stack flags (§12), and the attribute is what
  # the deployer reconciles before every deploy (§3, §9).
  def test_termination_protection_is_reflected_in_cloud_assembly_artifact
    stack = stack(termination_protection: true)

    assert_equal true, stack.termination_protection
  end

  # FINDING: the CDK refuses an account id that is not a String
  # ("Account id of stack environment must be a 'string' but received
  # 'number'", core/lib/stack.ts:1519 at the pinned commit). This tool accepts
  # a 12-digit Integer and writes it as a string: RubyCdk::Env.new(account:
  # 111111111111, region: "us-east-1") answers an Env of account
  # "111111111111" and nothing raises. Expected a refusal.
  # test('account id passed in stack environment must be a string')
  def test_account_id_passed_in_stack_environment_must_be_a_string
    error = assert_raises(ArgumentError) { RubyCdk::Env.new(account: 111111111111, region: "us-east-1") }

    assert_match(/account must be/, error.message)
  end

  # test('region passed in stack environment must be a string')
  # Changed: refused here for its shape rather than its type — the region must
  # look like eu-west-1 — where the CDK asks for a String (stack.ts:1523); a
  # raise is what both do.
  def test_region_passed_in_stack_environment_must_be_a_string
    error = assert_raises(ArgumentError) { RubyCdk::Env.new(account: "123456789012", region: 2) }

    assert_match(/region must look like/, error.message)
  end

  # test('indent templates when suppressTemplateIndentation is not set')
  # Changed: the CDK writes one space of indentation and no format version
  # key; the serialization contract here (§5, D-028) fixes two spaces and the
  # key.
  def test_indent_templates_when_suppress_template_indentation_is_not_set
    app = build_app
    RubyCdk::Stack.new(app, "Stack") { resource("MyResource", "MyResourceType") }
    manifest = app.synth

    bytes = File.binread(File.join(manifest.out_dir, manifest.entries.first.template))

    assert_match(
      /\A\{\n  "AWSTemplateFormatVersion": "2010-09-09",\n  "Resources": \{\n    "MyResource": \{\n      "Type": "MyResourceType"\n    \}\n  \}/,
      bytes
    )
  end

  # test('stack adds template-producer metadata to the cloud assembly')
  # Changed: the CDK writes the file name as metadata of the stack artifact;
  # the manifest here names the template in the stack's entry (§12).
  def test_stack_adds_template_producer_metadata_to_the_cloud_assembly
    app = build_app
    RubyCdk::Stack.new(app, "MyStack")
    manifest = app.synth

    entry = manifest.entries.first

    assert_equal "MyStack.template.json", entry.template
    assert File.file?(File.join(manifest.out_dir, entry.template))
  end

  # test('stack.addMetadata() adds metadata'), from describe('regionalFact')
  # but needing none of its machinery.
  def test_stack_add_metadata_adds_metadata
    stack = stack do
      add_metadata("Instances", { "Description" => "Information about the instances" })
      add_metadata("Databases", { "Description" => "Information about the databases" })
    end

    assert_equal(with_format_version(
      "Metadata" => {
        "Instances" => { "Description" => "Information about the instances" },
        "Databases" => { "Description" => "Information about the databases" }
      }
    ), stack.to_template)
  end

  # test('cannot create cyclic reference between stacks')
  def test_cannot_create_cyclic_reference_between_stacks
    app = RubyCdk::App.new(env: TEST_ENV)
    stack1 = RubyCdk::Stack.new(app, "Stack1")
    stack2 = RubyCdk::Stack.new(app, "Stack2")

    stack1.add_dependency(stack2)

    error = assert_raises(RubyCdk::UsageError) { stack2.add_dependency(stack1) }

    assert_match(/cyclic reference/, error.message)
  end

  # test('addStackDependency raises error on cycle')
  def test_add_dependency_raises_error_on_cycle
    app = RubyCdk::App.new(env: TEST_ENV)
    stack1 = RubyCdk::Stack.new(app, "Stack1")
    stack2 = RubyCdk::Stack.new(app, "Stack2")
    stack3 = RubyCdk::Stack.new(app, "Stack3")

    stack1.add_dependency(stack2)
    stack2.add_dependency(stack3)

    error = assert_raises(RubyCdk::UsageError) { stack3.add_dependency(stack1) }

    assert_match(/cyclic reference/, error.message)
    assert_match(/Stack1/, error.message)
  end
end
