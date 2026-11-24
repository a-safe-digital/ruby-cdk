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
        # from. Read in full from "CloudFormation resource specification",
        # https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/cfn-resource-specification.html,
        # on 2026-11-24, after the older revision this table was first written from had gone
        # stale: sixteen addresses had moved (eight no longer resolved, the Mexico bucket
        # gained an account ID, the GovCloud buckets moved off path-style addressing, and
        # ten more now sit behind CloudFront), and the page had grown four regions.
        #
        # The previous revision of this page had been the source of eleven dead addresses,
        # which is why the whole table is rewritten from the page rather than patched.
        #
        # Jakarta, Melbourne, Malaysia, Thailand, Canada West and both GovCloud regions serve
        # the file uncompressed: their addresses carry no /gzip/ segment. The parser reads
        # either form. The two China regions are on the page but their endpoints did not
        # answer from where this table was written (the connection failed; AWS serves them
        # from within China only); they are kept because the page is the reference and a
        # build there will work or fail loudly with a 404. The other twenty-five addresses
        # in the table answered HTTP 200 on 2026-11-24.
        SPECIFICATION_URLS = {
          "us-east-2" => "https://dnwj8swjjbsbt.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "us-east-1" => "https://d1uauaxba7bl26.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "us-west-1" => "https://d68hl49wbnanq.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "us-west-2" => "https://d201a2mn26r7lk.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "af-south-1" => "https://cfn-resource-specifications-af-south-1-prod.s3.af-south-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-east-1" => "https://cfn-resource-specifications-ap-east-1-prod.s3.ap-east-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-south-2" => "https://cfn-resource-specifications-ap-south-2-prod.s3.ap-south-2.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-southeast-3" => "https://cfn-resource-specifications-ap-southeast-3-prod.s3.ap-southeast-3.amazonaws.com/latest/CloudFormationResourceSpecification.json",
          "ap-southeast-4" => "https://cfn-resource-specifications-ap-southeast-4-prod.s3.ap-southeast-4.amazonaws.com/latest/CloudFormationResourceSpecification.json",
          "ap-southeast-5" => "https://cfn-resource-specifications-ap-southeast-5-prod.s3.ap-southeast-5.amazonaws.com/latest/CloudFormationResourceSpecification.json",
          "ap-east-2" => "https://cfn-resource-specifications-ap-east-2-975050364454-prod.s3.ap-east-2.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-southeast-7" => "https://cfn-resource-specifications-ap-southeast-7-767397843873-prod.s3.ap-southeast-7.amazonaws.com/latest/CloudFormationResourceSpecification.json",
          "ap-south-1" => "https://d2senuesg1djtx.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-northeast-3" => "https://d2zq80gdmjim8k.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-northeast-2" => "https://d1ane3fvebulky.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-southeast-1" => "https://doigdx0kgq9el.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-southeast-2" => "https://d2stg8d246z9di.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "ap-northeast-1" => "https://d33vqc0rt9ld30.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "ca-central-1" => "https://d2s8ygphhesbe7.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "ca-west-1" => "https://cfn-resource-specifications-ca-west-1-prod.s3.ca-west-1.amazonaws.com/latest/CloudFormationResourceSpecification.json",
          "cn-north-1" => "https://cfn-resource-specifications-cn-north-1-prod.s3.cn-north-1.amazonaws.com.cn/latest/gzip/CloudFormationResourceSpecification.json",
          "cn-northwest-1" => "https://cfn-resource-specifications-cn-northwest-1-prod.s3.cn-northwest-1.amazonaws.com.cn/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-central-1" => "https://d1mta8qj7i28i2.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-west-1" => "https://d3teyb21fexa9r.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-west-2" => "https://d1742qcu2c1ncx.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-south-1" => "https://cfn-resource-specifications-eu-south-1-prod.s3.eu-south-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-west-3" => "https://d2d0mfegowb3wk.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-south-2" => "https://cfn-resource-specifications-eu-south-2-prod.s3.eu-south-2.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-north-1" => "https://diy8iv58sj6ba.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "eu-central-2" => "https://cfn-resource-specifications-eu-central-2-prod.s3.eu-central-2.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "il-central-1" => "https://cfn-resource-specifications-il-central-1-prod.s3.il-central-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "me-south-1" => "https://cfn-resource-specifications-me-south-1-prod.s3.me-south-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "me-central-1" => "https://cfn-resource-specifications-me-central-1-prod.s3.me-central-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "mx-central-1" => "https://cfn-resource-specifications-mx-central-1-590183656522-prod.s3.mx-central-1.amazonaws.com/latest/gzip/CloudFormationResourceSpecification.json",
          "sa-east-1" => "https://d3c9jyj3w509b0.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json",
          "us-gov-east-1" => "https://s3.us-gov-east-1.amazonaws.com/cfn-resource-specifications-us-gov-east-1-prod/latest/CloudFormationResourceSpecification.json",
          "us-gov-west-1" => "https://s3.us-gov-west-1.amazonaws.com/cfn-resource-specifications-us-gov-west-1-prod/latest/CloudFormationResourceSpecification.json"
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
