# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/aws-cdk-lib/aws-s3/test/bucket.test.ts, in aws/aws-cdk
#   Commit:  c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-25)
#   Licence: Apache-2.0. The AWS CDK's test scenarios; this file's wording is this repository's.
#
# The origin has 200 cases. Each ported one keeps its name, as a comment above
# the test, and what it expects. What changed to get there:
#
#   - The origin's `new Stack()` is `stack` here, `Template.fromStack` is
#     `template`; every whole-template expectation adds AWSTemplateFormatVersion
#     (with_format_version), which the serialization contract writes here always.
#   - The logical ID is the ids above the resource joined, never hashed
#     (D-004, D-029): MyBucketF68F3FF0 is MyBucketResource here.
#   - The grants are given to an IAM::Role, not to a User: this wave ships no
#     User construct, and a Role is the IGrantable every construct's grant
#     targets here. The statements are the origin's, the two resource ARNs
#     included; the policy carries Roles where the origin's carries Users, and
#     its PolicyName and logical ID are this tool's (no hash behind them).
#
# Changed expectations, stated next to the test:
#
#   - "default bucket": the CDK's default template carries no Properties at
#     all - it writes no PublicAccessBlockConfiguration, leaning on S3's
#     account-level default, and no BucketEncryption, because S3 applies SSE-S3
#     to every bucket without a rule. Here public access blocked on all four
#     settings and the SSE-S3 rule are written into the template, so that a
#     bucket is private and encrypted wherever it lands (architecture section 7
#     wins; the two rows are in section 21). The origin's expectation is
#     otherwise kept: nothing else is written, and the bucket is retained.
#
# Not ported, with the reason:
#
#   Not ported because this tool does not have the feature:
#   - CFN properties are type-validated during resolution (a Token made of a
#     number). There are no tokens here: a physical name is a literal or
#     nothing.
#   - importing: fromBucketName / fromBucketAttributes / fromBucketArn, the
#     underscore legacy-naming cases, the encryption attribute of an imported
#     bucket. Lookups of existing resources are not in 0.1.0 (D-022).
#   - blockedEncryptionTypes, and bucket with no encryption by default and
#     blockedEncryptionTypes, and bucket with default encryption and
#     blockedEncryptionTypes. No BlockedEncryptionTypes prop in this wave.
#   - encryptionKey cases: fails if encryption key is used with managed
#     encryption (three), encryptionKey can specify kms key, dsse encryptionKey
#     can specify kms key, KMS key is generated if encryption is KMS. There is
#     no KMS Key construct in this wave; the bucket takes s3_managed or
#     kms_managed, and a customer-managed key arrives with that construct.
#   - enforceSSL, minimumTLSVersion, and the deny-insecure-transport policy
#     they put on the bucket. The bootstrap stack writes that policy as an L1
#     (lib/ruby_cdk/bootstrap.rb); the prop joins when the policy machinery of
#     the constructs does.
#   - bucketKeyEnabled cases. No bucket key without a KMS key construct.
#   - server access logging (logs to self / logs to separate bucket, eight
#     cases). No logging configuration prop in this wave.
#   - bucketNamePrefix and bucketNamespace cases (nine). No such props here.
#   - object lock cases (nine). No object lock prop in this wave.
#   - public access block feature-flag cases (S3_PUBLIC_ACCESS_BLOCKED_BY_DEFAULT
#     disabled/enabled, and the BlockAcls / BLOCK_ACLS_ONLY shapes). There are
#     no feature flags here: the four settings are always written, true by
#     default, fillable from a Hash.
#   - publicReadAccess and the "default block public access setting to throw
#     error msg" cases. No publicReadAccess prop in this wave.
#   - access control and ownershipControls cases (bucket with custom canned
#     access control, and the objectOwnership cases around it). No ACL props
#     here; S3's recommended default (bucket owner enforced) applies as the
#     service's own.
#   - the shared bucket policy cases (L2 addToResourcePolicy and
#     ResourceWithPolicies.of share a single bucket policy). No
#     addToResourcePolicy in this wave: grants go to the principal's policy.
#   - lifecycle rules, CORS, metrics, notifications, website configuration,
#     intelligent tiering, replication, inventory, transfer acceleration, ABAC
#     status, the deprecated azure cases, and the rest of the prop surface.
#     Each is a prop this wave does not carry; the L1 resource: remains the way
#     to write one, exactly as the CDK's CfnBucket is.
#   - grants to non-identity principals (OrganizationPrincipal and the like),
#     grants across stacks, grantPut / grantDelete / grantPublicAccess /
#     grantReplicationPermission and the key-grant cases. The grants of this
#     wave are grant_read and grant_read_write, to identities; the rest arrive
#     with the constructs they need.
#
# Parity: 200 cases in the origin; 11 ported; 189 not ported.

require "test_helper"
require "support/cdk_constructs"

class CdkConstructsBucketTest < CdkConstructs::TestCase
  def test_default_bucket
    # Changed: public access blocked on all four settings and the SSE-S3 rule
    # are written into the template here (see the header).
    built = stack do
      RubyCdk::S3::Bucket.new(self, "MyBucket")
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyBucketResource" => {
          "Type" => "AWS::S3::Bucket",
          "DeletionPolicy" => "RetainExceptOnCreate",
          "UpdateReplacePolicy" => "Retain",
          "Properties" => {
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
            }
          }
        }
      }
    ))
  end

  def test_bucket_with_s3_managed_encryption
    built = stack do
      RubyCdk::S3::Bucket.new(self, "MyBucket", encryption: :s3_managed)
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyBucketResource" => {
          "Type" => "AWS::S3::Bucket",
          "DeletionPolicy" => "RetainExceptOnCreate",
          "UpdateReplacePolicy" => "Retain",
          "Properties" => {
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
            }
          }
        }
      }
    ))
  end

  def test_bucket_with_kms_managed_encryption
    built = stack do
      RubyCdk::S3::Bucket.new(self, "MyBucket", encryption: :kms_managed)
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyBucketResource" => {
          "Type" => "AWS::S3::Bucket",
          "DeletionPolicy" => "RetainExceptOnCreate",
          "UpdateReplacePolicy" => "Retain",
          "Properties" => {
            "BucketEncryption" => {
              "ServerSideEncryptionConfiguration" => [
                { "ServerSideEncryptionByDefault" => { "SSEAlgorithm" => "aws:kms" } }
              ]
            },
            "PublicAccessBlockConfiguration" => {
              "BlockPublicAcls" => true,
              "BlockPublicPolicy" => true,
              "IgnorePublicAcls" => true,
              "RestrictPublicBuckets" => true
            }
          }
        }
      }
    ))
  end

  def test_bucket_with_versioning_turned_on
    built = stack do
      RubyCdk::S3::Bucket.new(self, "MyBucket", versioned: true)
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "MyBucketResource" => {
          "Type" => "AWS::S3::Bucket",
          "DeletionPolicy" => "RetainExceptOnCreate",
          "UpdateReplacePolicy" => "Retain",
          "Properties" => {
            "VersioningConfiguration" => { "Status" => "Enabled" },
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
            }
          }
        }
      }
    ))
  end

  def test_valid_bucket_names
    stack do
      RubyCdk::S3::Bucket.new(self, "MyBucket1", bucket_name: "abc.xyz-34ab")
      RubyCdk::S3::Bucket.new(self, "MyBucket2", bucket_name: "124.pp--33")
    end
  end

  def test_creating_bucket_with_underscore_in_name_throws_error
    assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::S3::Bucket.new(self, "TestBucket", bucket_name: "test_bucket_name")
      end
    end
  end

  def test_fails_if_bucket_name_has_less_than_3_or_more_than_63_characters
    assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::S3::Bucket.new(self, "MyBucket1", bucket_name: "a")
      end
    end

    assert_raises(RubyCdk::UsageError) do
      stack do
        RubyCdk::S3::Bucket.new(self, "MyBucket2", bucket_name: "x" * 64)
      end
    end
  end

  def test_fails_if_bucket_name_has_invalid_characters
    {
      "b@cket" => /offset: 1/,
      "bucKet" => /offset: 3/,
      "bučket" => /offset: 2/
    }.each do |name, expected|
      error = assert_raises(RubyCdk::UsageError) do
        stack do
          RubyCdk::S3::Bucket.new(self, "MyBucket", bucket_name: name)
        end
      end

      assert_match expected, error.message
    end
  end

  def test_fails_if_bucket_name_does_not_start_or_end_with_lowercase_character_or_number
    {
      "-ucket" => /offset: 0/,
      "bucke." => /offset: 5/
    }.each do |name, expected|
      error = assert_raises(RubyCdk::UsageError) do
        stack do
          RubyCdk::S3::Bucket.new(self, "MyBucket", bucket_name: name)
        end
      end

      assert_match expected, error.message
    end
  end

  def test_grant_read
    # Changed: granted to a Role, not to a User (see the header).
    built = stack do
      bucket = RubyCdk::S3::Bucket.new(self, "MyBucket")
      reader = RubyCdk::IAM::Role.new(self, "Reader", assumed_by: "lambda.amazonaws.com")
      bucket.grant_read(reader)
    end

    template(built).template_matches(with_format_version(
      "Resources" => {
        "ReaderDefaultPolicy" => {
          "Type" => "AWS::IAM::Policy",
          "Properties" => {
            "PolicyDocument" => {
              "Statement" => [
                {
                  "Action" => [ "s3:GetObject*", "s3:GetBucket*", "s3:List*" ],
                  "Effect" => "Allow",
                  "Resource" => [
                    { "Fn::GetAtt" => [ "MyBucketResource", "Arn" ] },
                    {
                      "Fn::Join" => [ "", [
                        { "Fn::GetAtt" => [ "MyBucketResource", "Arn" ] },
                        "/*"
                      ] ]
                    }
                  ]
                }
              ],
              "Version" => "2012-10-17"
            },
            "PolicyName" => "ReaderDefaultPolicy",
            "Roles" => [ { "Ref" => "ReaderResource" } ]
          }
        },
        "ReaderResource" => { "Type" => "AWS::IAM::Role" },
        "MyBucketResource" => { "Type" => "AWS::S3::Bucket" }
      }
    ))
  end

  def test_can_be_used_to_grant_reciprocal_permissions_to_an_identity
    # Changed: granted to a Role, not to a User (see the header); asserted on
    # the statement, the way the origin's describes block does.
    built = stack do
      bucket = RubyCdk::S3::Bucket.new(self, "MyBucket")
      user = RubyCdk::IAM::Role.new(self, "MyUser", assumed_by: "lambda.amazonaws.com")
      bucket.grant_read_write(user)
    end

    template(built).has_resource_properties("AWS::IAM::Policy", {
      "PolicyDocument" => {
        "Statement" => [
          {
            "Action" => [
              "s3:GetObject*", "s3:GetBucket*", "s3:List*",
              "s3:DeleteObject*",
              "s3:PutObject", "s3:PutObjectLegalHold", "s3:PutObjectRetention",
              "s3:PutObjectTagging", "s3:PutObjectVersionTagging", "s3:Abort*"
            ],
            "Effect" => "Allow",
            "Resource" => [
              { "Fn::GetAtt" => [ "MyBucketResource", "Arn" ] },
              {
                "Fn::Join" => [ "", [
                  { "Fn::GetAtt" => [ "MyBucketResource", "Arn" ] },
                  "/*"
                ] ]
              }
            ]
          }
        ],
        "Version" => "2012-10-17"
      },
      "Roles" => [ { "Ref" => "MyUserResource" } ]
    })
  end
end
