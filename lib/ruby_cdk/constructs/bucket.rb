# frozen_string_literal: true

require_relative "../errors"
require_relative "../fn"
require_relative "grant"

module RubyCdk
  module S3
    # An S3 bucket: the port of the CDK's Bucket (aws-s3/lib/bucket.ts), read
    # at commit c070afb54b9e4dbddd52a85a21077fe970354985, Apache-2.0.
    #
    #   RubyCdk::S3::Bucket.new(stack, "Images",
    #     versioned: true, bucket_name: "my-images-1a2b3c4d")
    #
    # Defaults, and where they differ from the CDK (architecture section 7
    # wins; both rows are listed in section 21):
    #
    #   - Public access is blocked on all four settings, written out. The CDK
    #     writes no PublicAccessBlockConfiguration and leans on S3's
    #     account-level default (bucket.ts, setDefaultPublicAccessBlockConfig:
    #     "this is already the case as an s3 default in aws"); here the four
    #     settings travel with the template, so the bucket is private wherever
    #     it lands. public_access_block: false writes all four as false, and a
    #     Hash fills its missing keys with true, as the CDK's
    #     S3_PUBLIC_ACCESS_BLOCKED_BY_DEFAULT behaviour does.
    #   - Encryption is on: ServerSideEncryptionConfiguration with AES256
    #     (S3_MANAGED) is written out. The CDK writes no BucketEncryption,
    #     because S3 applies SSE-S3 to every bucket without a rule (bucket.ts,
    #     parseEncryption: UNENCRYPTED is its default); the written rule is the
    #     same encryption, stated. encryption: :kms_managed writes aws:kms with
    #     the AWS-managed key, as KMS_MANAGED does; encryption: nil leaves the
    #     key out entirely.
    #   - The bucket is a retained type (architecture section 7), which the
    #     synthesis gives every AWS::S3::Bucket, as the CDK's
    #     applyRemovalPolicy does.
    #
    # The grants are the CDK's read and readWrite (aws-s3/lib/bucket-grants.ts
    # and perms.ts, at the same commit): read is s3:GetObject*, s3:GetBucket*
    # and s3:List* on the bucket ARN and on the objects' ARN; read_write adds
    # the delete and put actions. A bucket encrypted with a KMS key here has no
    # key object to grant on, so the kms:* actions the CDK adds on the key are
    # not granted; use encryption: :kms_managed only with principals that
    # already may use aws/s3.
    class Bucket < Construct
      # The four settings, all true, as the CDK's BlockPublicAccess.BLOCK_ALL.
      PUBLIC_ACCESS_BLOCK = {
        "BlockPublicAcls" => true,
        "BlockPublicPolicy" => true,
        "IgnorePublicAcls" => true,
        "RestrictPublicBuckets" => true
      }.freeze

      # The CDK's read actions for a bucket and its objects
      # (aws-s3/lib/perms.ts, BUCKET_READ_ACTIONS).
      READ_ACTIONS = [ "s3:GetObject*", "s3:GetBucket*", "s3:List*" ].freeze

      # The read plus delete and put actions of readWrite, in the CDK's order:
      # BUCKET_READ_ACTIONS, then BUCKET_DELETE_ACTIONS and the put actions of
      # S3_GRANT_WRITE_WITHOUT_ACL (perms.ts, BUCKET_PUT_ACTIONS).
      READ_WRITE_ACTIONS = [
        "s3:GetObject*", "s3:GetBucket*", "s3:List*",
        "s3:DeleteObject*",
        "s3:PutObject", "s3:PutObjectLegalHold", "s3:PutObjectRetention",
        "s3:PutObjectTagging", "s3:PutObjectVersionTagging", "s3:Abort*"
      ].freeze

      attr_reader :encryption, :public_access_block

      def initialize(scope, id, bucket_name: nil, versioned: false, encryption: :s3_managed, public_access_block: nil)
        super(scope, id)
        @encryption = valid_encryption(encryption)
        @bucket_name = valid_bucket_name(bucket_name)
        @public_access_block = public_access_settings(public_access_block)

        @resource = resource("Resource", "AWS::S3::Bucket",
          BucketName: @bucket_name,
          BucketEncryption: encryption_property,
          VersioningConfiguration: versioned ? { "Status" => "Enabled" } : nil,
          PublicAccessBlockConfiguration: @public_access_block)
      end

      # The bucket's ARN.
      def arn
        Fn.get_att(@resource, "Arn")
      end

      # The bucket's name: the one given, or the Ref of the resource.
      def bucket_name
        @bucket_name || Fn.ref(@resource)
      end

      # The ARN of the bucket's objects under key_pattern, as the CDK's
      # arnForObjects: the bucket ARN, then the pattern.
      def objects_arn(key_pattern = "*")
        unless key_pattern.is_a?(String) && !key_pattern.empty?
          raise UsageError, "#{path}: objects_arn takes a key pattern String, got #{key_pattern.inspect}"
        end

        Fn.join("", [ arn, "/#{key_pattern}" ])
      end

      # Grants read on the bucket and its contents to the principal: the CDK's
      # grantRead (bucket-grants.ts, read). An IAM::Role carries the statement
      # on its own policy; a principal named by ARN gets the Grant back
      # unapplied.
      def grant_read(principal, objects_key_pattern: "*")
        Constructs::Grant.add_to_principal(principal, READ_ACTIONS, [ arn, objects_arn(objects_key_pattern) ])
      end

      # Grants read and write: the CDK's grantReadWrite (bucket-grants.ts,
      # readWrite, with the put actions its S3_GRANT_WRITE_WITHOUT_ACL flag
      # enables).
      def grant_read_write(principal, objects_key_pattern: "*")
        Constructs::Grant.add_to_principal(principal, READ_WRITE_ACTIONS, [ arn, objects_arn(objects_key_pattern) ])
      end

      private

      def valid_encryption(value)
        return value if value.nil? || %i[s3_managed kms_managed].include?(value)

        raise UsageError, "#{path}: encryption takes :s3_managed, :kms_managed or nil, got #{value.inspect}"
      end

      # S3's own rules for a bucket name, as the CDK validates them
      # (bucket.ts, _validateBucketName, read at the commit in the header):
      # 3 to 63 characters, lower-case letters, digits, dots and hyphens,
      # starting and ending with a letter or a digit, no period next to a dash
      # and no consecutive periods, and no name that resembles an IP address.
      def valid_bucket_name(name)
        return nil if name.nil?
        unless name.is_a?(String) && !name.empty?
          raise UsageError, "#{path}: the bucket name must be a String, got #{name.inspect}"
        end

        errors = bucket_name_errors(name)
        return name if errors.empty?

        raise UsageError, "Invalid S3 bucket name (value: #{name})#{errors.map { |error| "\n  #{error}" }.join}"
      end

      # The CDK's rule list, with its own words and offsets.
      def bucket_name_errors(name)
        errors = []
        errors << "Bucket name must be at least 3 and no more than 63 characters" if name.length < 3 || name.length > 63
        if (offset = name.index(/[^a-z0-9.-]/))
          errors << "Bucket name must only contain lowercase characters and the symbols, period (.) and dash (-) (offset: #{offset})"
        end
        errors << "Bucket name must start with a lowercase character or number (offset: 0)" unless name.match?(/\A[a-z0-9]/)
        errors << "Bucket name must end with a lowercase character or number (offset: #{name.length - 1})" unless name.match?(/[a-z0-9]\z/)
        if (offset = name.index(/\.-|-\.|\.\./))
          errors << "Bucket name must not have dash next to period, or period next to dash, or consecutive periods (offset: #{offset})"
        end
        errors << "Bucket name must not resemble an IP address" if name.match?(/\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/)
        errors
      end

      def public_access_settings(value)
        case value
        when nil then PUBLIC_ACCESS_BLOCK.dup
        when false then PUBLIC_ACCESS_BLOCK.to_h { |key, _| [ key, false ] }
        when true then PUBLIC_ACCESS_BLOCK.dup
        when Hash
          PUBLIC_ACCESS_BLOCK.to_h { |key, default| [ key, value.key?(key) ? value[key] : default ] }
        else
          raise UsageError, "#{path}: public_access_block takes true, false or a Hash of the four settings, got #{value.inspect}"
        end
      end

      # The CDK's rendering per mode (bucket.ts, parseEncryption): SSE-S3 is
      # the AES256 algorithm, KMS_MANAGED the aws:kms one with the AWS-managed
      # key, and nothing is written when encryption is nil.
      def encryption_property
        return nil if @encryption.nil?

        algorithm = @encryption == :kms_managed ? "aws:kms" : "AES256"
        {
          "ServerSideEncryptionConfiguration" => [
            { "ServerSideEncryptionByDefault" => { "SSEAlgorithm" => algorithm } }
          ]
        }
      end
    end
  end
end
