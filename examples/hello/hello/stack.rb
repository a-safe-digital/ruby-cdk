# frozen_string_literal: true

require "ruby-cdk"

module Hello
  # One S3 bucket that stays private: public access blocked on all four
  # settings, and encrypted at rest.
  #
  # The bucket is an L1 resource, written with CloudFormation's own property
  # names. A parameter decides whether it keeps every version of an object, and
  # an output gives its name, so that a deploy exercises both.
  class Stack < RubyCdk::Stack
    def build
      versioning = parameter("Versioning", type: "String", default: "Suspended", allowed_values: [ "Suspended", "Enabled" ],
        description: "Whether the bucket keeps every version of an object")

      bucket = resource("Bucket", "AWS::S3::Bucket", properties: {
        "BucketEncryption" => {
          "ServerSideEncryptionConfiguration" => [
            { "ServerSideEncryptionByDefault" => { "SSEAlgorithm" => "AES256" } }
          ]
        },
        "PublicAccessBlockConfiguration" => {
          "BlockPublicAcls" => true,
          "BlockPublicPolicy" => true,
          "IgnorePublicAcls" => true,
          "RestrictPublicBuckets" => true
        },
        "VersioningConfiguration" => { "Status" => Fn.ref(versioning) }
      })

      output("BucketName", value: Fn.ref(bucket), description: "The name of the bucket")
    end
  end
end
