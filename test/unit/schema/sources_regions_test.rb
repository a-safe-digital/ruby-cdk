# frozen_string_literal: true

require "test_helper"
require_relative "../../support/schema_fixtures"

# Where each region's two sources live.
class SourcesRegionsTest < Minitest::Test
  Regions = RubyCdk::Schema::Sources::Regions
  SPECIFICATION = "latest/gzip/CloudFormationResourceSpecification.json"

  def test_the_three_regions_the_brief_names
    {
      "us-east-1" => "https://d1uauaxba7bl26.cloudfront.net/#{SPECIFICATION}",
      "eu-west-1" => "https://d3tepb21wu62n48.cloudfront.net/#{SPECIFICATION}",
      "us-west-2" => "https://d1alt0rnwa63ox.cloudfront.net/#{SPECIFICATION}"
    }.each do |region, specification|
      assert_equal "https://schema.cloudformation.#{region}.amazonaws.com/CloudformationSchema.zip", Regions.urls(region)[:provider_schemas]
      assert_equal specification, Regions.urls(region)[:resource_specification]
    end
  end

  def test_an_unknown_region_is_refused_with_how_to_fix_it
    error = assert_raises(Regions::Unknown) { Regions.urls("ap-south-9") }

    assert_kind_of RubyCdk::Error, error
    assert_match(/"ap-south-9" is not in the specification table/, error.message)
    assert_match(%r{lib/ruby_cdk/schema/sources/regions\.rb}, error.message)
  end
end
