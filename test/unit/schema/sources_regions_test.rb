# frozen_string_literal: true

require "test_helper"
require_relative "../../support/schema_fixtures"

# Where each region's two sources live.
class SourcesRegionsTest < Minitest::Test
  Regions = RubyCdk::Schema::Sources::Regions
  SPECIFICATION = "latest/gzip/CloudFormationResourceSpecification.json"

  def test_the_regions_the_first_builds_used
    {
      "us-east-1" => "https://d1uauaxba7bl26.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
      "eu-west-1" => "https://d3teyb21fexa9r.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
      "us-west-2" => "https://d201a2mn26r7lk.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json"
    }.each do |region, specification|
      assert_equal "https://schema.cloudformation.#{region}.amazonaws.com/CloudformationSchema.zip", Regions.urls(region)[:provider_schemas]
      assert_equal specification, Regions.urls(region)[:resource_specification]
    end
  end

  # The page serves some regions uncompressed; the parser reads either form.
  def test_the_uncompressed_addresses
    {
      "ap-southeast-3" => "https://cfn-resource-specifications-ap-southeast-3-prod.s3.ap-southeast-3.amazonaws.com/latest/CloudFormationResourceSpecification.json",
      "us-gov-west-1" => "https://s3.us-gov-west-1.amazonaws.com/cfn-resource-specifications-us-gov-west-1-prod/latest/CloudFormationResourceSpecification.json"
    }.each do |region, specification|
      refute_includes Regions.urls(region)[:resource_specification], "/gzip/"
      assert_equal specification, Regions.urls(region)[:resource_specification]
    end
  end

  def test_every_address_on_the_page_is_in_the_table
    assert_equal 37, Regions::SPECIFICATION_URLS.size
    %w[cn-north-1 cn-northwest-1 ap-east-2 ap-southeast-7].each { |region| assert_includes Regions::SPECIFICATION_URLS, region }
    assert Regions::SPECIFICATION_URLS.values.all? { |url| url.end_with?("CloudFormationResourceSpecification.json") }
  end

  def test_an_unknown_region_is_refused_with_how_to_fix_it
    error = assert_raises(Regions::Unknown) { Regions.urls("ap-south-9") }

    assert_kind_of RubyCdk::Error, error
    assert_match(/"ap-south-9" is not in the specification table/, error.message)
    assert_match(%r{lib/ruby_cdk/schema/sources/regions\.rb}, error.message)
  end
end
