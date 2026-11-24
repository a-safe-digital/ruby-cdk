# frozen_string_literal: true

require_relative "support"

# The normalizer (architecture §6): key resolution and the verbatim zones.
class ValidationNormalizerTest < Minitest::Test
  include ValidationCase

  def test_an_exact_property_name_is_used_as_is
    normalized = normalize("pass-minimal")

    assert_equal "BucketName", normalized.dig("Resources", "Bucket", "Properties").keys.first
  end

  def test_a_key_in_snake_case_becomes_the_canonical_name
    normalized = normalize("pass-snake-case")
    properties = normalized.dig("Resources", "Bucket", "Properties")

    assert_equal %w[BucketName OwnershipControls PublicAccessBlockConfiguration], properties.keys.sort
    assert_equal "BlockPublicAcls", properties.dig("PublicAccessBlockConfiguration").keys.first
    assert_equal "ObjectOwnership", properties.dig("OwnershipControls", "Rules", 0).keys.first
  end

  def test_a_key_the_model_reads_one_way_of_is_resolved
    template = {
      "Resources" => {
        "Table" => {
          "Type" => "AWS::DynamoDB::Table",
          "Properties" => {
            "sse_specification" => { "sse_enabled" => true, "kms_master_key_id" => "arn:aws:kms:us-east-1:123456789012:key/one" }
          }
        },
        "Volume" => {
          "Type" => "AWS::EC2::Volume",
          "Properties" => { "iops" => 3000 }
        }
      }
    }

    normalized = RubyCdk::Validation::Normalizer.normalize(template)

    assert_equal %w[KMSMasterKeyId SSEEnabled], normalized.dig("Resources", "Table", "Properties", "SSESpecification").keys.sort
    assert_equal "Iops", normalized.dig("Resources", "Volume", "Properties").keys.first
  end

  def test_a_key_that_names_nothing_is_left_as_it_was_written
    normalized = normalize("v3-unresolvable-snake")

    assert_equal "cors_config", normalized.dig("Resources", "Bucket", "Properties").keys.grep(/cors/).first
  end

  def test_a_policy_document_is_verbatim_and_its_symbols_become_strings
    normalized = normalize("verbatim-policy-document")
    document = normalized.dig("Resources", "Role", "Properties", "AssumeRolePolicyDocument")

    assert_equal "AssumeRolePolicyDocument", normalized.dig("Resources", "Role", "Properties").keys.grep(/ssume/).first
    assert_equal %w[Statement Version], document.keys.sort
    assert_equal %w[Effect Principal Action condition], document.dig("Statement", 0).keys
    assert_equal %w[aws:MultiFactorAuthPresent], document.dig("Statement", 0, "condition").keys
  end

  def test_resource_metadata_is_verbatim
    normalized = normalize("verbatim-metadata")

    assert_equal %w[Kept_As_Written aws:cloudformation:some], normalized.dig("Resources", "Bucket", "Metadata").keys.sort
    assert_equal %w[Nested.Key], normalized.dig("Resources", "Bucket", "Metadata", "Kept_As_Written").keys
  end

  def test_snake_case_inside_a_branch_of_an_fn_if_is_resolved
    template = {
      "Conditions" => { "IsProd" => { "Fn::Equals" => [ "a", "a" ] } },
      "Resources" => {
        "Bucket" => {
          "Type" => "AWS::S3::Bucket",
          "Properties" => {
            "access_control" => { "Fn::If" => [ "IsProd", "private", "public_read" ] }
          }
        }
      }
    }

    normalized = RubyCdk::Validation::Normalizer.normalize(template)

    assert_equal "AccessControl", normalized.dig("Resources", "Bucket", "Properties").keys.first
  end

  def test_a_type_the_model_does_not_know_is_verbatim
    template = {
      "Resources" => {
        "Thing" => { "Type" => "Custom::Thing", "Properties" => { "any_key_Here" => { "Inner_Key" => 1 } } }
      }
    }

    normalized = RubyCdk::Validation::Normalizer.normalize(template)

    assert_equal %w[any_key_Here], normalized.dig("Resources", "Thing", "Properties").keys
    assert_equal %w[Inner_Key], normalized.dig("Resources", "Thing", "Properties", "any_key_Here").keys
  end

  def test_the_template_it_was_given_is_not_changed
    template = fixture("pass-snake-case")
    frozen_copy = Marshal.load(Marshal.dump(template))

    RubyCdk::Validation::Normalizer.normalize(template)

    assert_equal frozen_copy, template
  end

  def test_a_normalizer_answers_the_pipeline
    normalizer = RubyCdk::Validation.normalizers.first
    context = RubyCdk::Validation::Context.new(stack: nil, template: fixture("pass-minimal"), issues: [])

    assert_kind_of Hash, normalizer.call(context)
  end

  def test_something_that_is_not_a_template_is_returned_as_it_is
    assert_equal "x", RubyCdk::Validation::Normalizer.normalize("x")
    assert_nil RubyCdk::Validation::Normalizer.normalize(nil)
  end

  private

  def normalize(name)
    RubyCdk::Validation::Normalizer.normalize(fixture(name))
  end
end
