# frozen_string_literal: true

require_relative "../../errors"

module RubyCdk
  module Schema
    module Sources
      # Where each region publishes the two sources.
      module Regions
        # Raised for a region that is not in the table.
        class Unknown < RubyCdk::Error; end

        # The provider schemas follow one pattern in every region.
        PROVIDER_URL = "https://schema.cloudformation.%<region>s.amazonaws.com/CloudformationSchema.zip"

        # The resource specification has one address per region, with no pattern to derive it
        # from. The addresses are the ones in "AWS CloudFormation resource specification
        # reference", the page architecture section 6 links.
        #
        # us-east-1 was fetched on 2026-11-23. The others are written from that page and were
        # not fetched: the brief allows the task two downloads, and this one. An address that
        # is wrong fails loudly, with a 404, the first time somebody builds its region.
        SPECIFICATION_URLS = {
          "af-south-1" => "https://cfn-resource-specifications-af-south-1-prod.s3.af-south-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-east-1" => "https://cfn-resource-specifications-ap-east-1-prod.s3.ap-east-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-northeast-1" => "https://cfn-resource-specifications-ap-northeast-1-prod.s3.ap-northeast-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-northeast-2" => "https://cfn-resource-specifications-ap-northeast-2-prod.s3.ap-northeast-2.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-northeast-3" => "https://cfn-resource-specifications-ap-northeast-3-prod.s3.ap-northeast-3.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-south-1" => "https://cfn-resource-specifications-ap-south-1-prod.s3.ap-south-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-south-2" => "https://cfn-resource-specifications-ap-south-2-prod.s3.ap-south-2.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-southeast-1" => "https://cfn-resource-specifications-ap-southeast-1-prod.s3.ap-southeast-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-southeast-2" => "https://cfn-resource-specifications-ap-southeast-2-prod.s3.ap-southeast-2.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-southeast-3" => "https://cfn-resource-specifications-ap-southeast-3-prod.s3.ap-southeast-3.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-southeast-4" => "https://cfn-resource-specifications-ap-southeast-4-prod.s3.ap-southeast-4.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-southeast-5" => "https://cfn-resource-specifications-ap-southeast-5-prod.s3.ap-southeast-5.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ca-central-1" => "https://cfn-resource-specifications-ca-central-1-prod.s3.ca-central-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ca-west-1" => "https://cfn-resource-specifications-ca-west-1-prod.s3.ca-west-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-central-1" => "https://cfn-resource-specifications-eu-central-1-prod.s3.eu-central-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-central-2" => "https://cfn-resource-specifications-eu-central-2-prod.s3.eu-central-2.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-north-1" => "https://diu8rcedcuawz.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-south-1" => "https://cfn-resource-specifications-eu-south-1-prod.s3.eu-south-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-south-2" => "https://cfn-resource-specifications-eu-south-2-prod.s3.eu-south-2.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-west-1" => "https://d3tepb21wu62n48.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-west-2" => "https://d3l5ou6uzftbhn.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-west-3" => "https://d3ozjqmj2m6cp8.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "il-central-1" => "https://cfn-resource-specifications-il-central-1-prod.s3.il-central-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "me-central-1" => "https://cfn-resource-specifications-me-central-1-prod.s3.me-central-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "me-south-1" => "https://cfn-resource-specifications-me-south-1-prod.s3.me-south-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "mx-central-1" => "https://cfn-resource-specifications-mx-central-1-prod.s3.mx-central-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "sa-east-1" => "https://d3a9s42c4hl1rn.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "us-east-1" => "https://d1uauaxba7bl26.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "us-east-2" => "https://dnwj8sw98s923.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "us-gov-east-1" => "https://cfn-resource-specifications-govcloud-prod.s3.us-gov-west-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification-usc-gov.json",
          "us-gov-west-1" => "https://cfn-resource-specifications-govcloud-prod.s3.us-gov-west-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification-usg.json",
          "us-west-1" => "https://d68hu5ybpjme5.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "us-west-2" => "https://d1alt0rnwa63ox.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json"
        }.freeze

        class << self
          # { provider_schemas: url, resource_specification: url } for one region.
          def urls(region)
            specification = SPECIFICATION_URLS[region] or
              raise Unknown, "#{region.inspect} is not in the specification table (lib/ruby_cdk/schema/sources/regions.rb). " \
                             "Add its address from the AWS CloudFormation resource specification reference, or build one of: #{SPECIFICATION_URLS.keys.join(", ")}"
            { provider_schemas: format(PROVIDER_URL, region:), resource_specification: specification }
          end
        end
      end
    end
  end
end
