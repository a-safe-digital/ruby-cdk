# frozen_string_literal: true

require_relative "../errors"
require_relative "zipper"

module RubyCdk
  module Assets
    # The asset bucket exists but is not ours, or does not exist at all.
    # Nothing was uploaded.
    class BucketUnavailableError < Error
      # state: what the port answered, :foreign or :absent.
      attr_reader :bucket, :state

      def initialize(bucket, state, owner)
        @bucket = bucket
        @state = state
        super(sentence(bucket, state, owner))
      end

      private

      def sentence(bucket, state, owner)
        case state
        when :foreign
          "Bucket named '#{bucket}' exists, but we don't have access to it as account #{owner}: its owner is not " \
          "that account (unexpected bucket owner), so nothing was uploaded. The bucket's name is predictable and " \
          "somebody else may be holding it. Find out who owns it before you go on; `ruby-cdk bootstrap` refuses it too."
        when :absent
          "No bucket named '#{bucket}' in account #{owner}, so nothing was uploaded. Run `ruby-cdk bootstrap` first."
        else
          "The object store answered #{state.inspect} for bucket '#{bucket}' in account #{owner}, " \
          "which is neither :mine, :foreign nor :absent. Nothing was uploaded."
        end
      end
    end

    # Uploads assets to a bucket through the object-store port, and never
    # talks to S3 in any other way. Every call names the account that must own
    # the bucket, and a bucket that is not theirs is refused before anything
    # is uploaded.
    class Uploader
      ACCOUNT_ID = /\A\d{12}\z/

      # store: an object store, with the three methods of the port.
      # owner: the 12-digit ID of the account that must own the bucket.
      def initialize(store:, owner:)
        account = owner.to_s
        unless ACCOUNT_ID.match?(account)
          raise ArgumentError, "owner must be the 12-digit ID of the account that owns the bucket, not #{owner.inspect}"
        end

        @store = store
        @owner = account
      end

      # Uploads the zip of the record unless its key is already in the bucket.
      # Answers :uploaded or :skipped.
      #
      # Raises BucketUnavailableError when the bucket belongs to another
      # account or does not exist, before anything is looked up or uploaded,
      # and what Zipper.build raises while the zip is built.
      def upload(record, bucket:)
        ensure_ours(bucket)
        put_unless_present(record, bucket)
      end

      # Uploads every record and answers { uploaded:, skipped: }, the counts of
      # records uploaded and of records left alone because their key was
      # already in the bucket.
      #
      # An empty list is not a request: { uploaded: 0, skipped: 0 } is answered
      # and the store is not called, the bucket's owner included. A stack with
      # no assets deploys into an account that was never bootstrapped.
      #
      # Otherwise the bucket's owner is checked once, for the whole batch. A
      # key that appears more than once is uploaded once; its later
      # appearances count as skipped and make no call.
      def upload_all(records, bucket:)
        counts = { uploaded: 0, skipped: 0 }
        return counts if records.empty?

        ensure_ours(bucket)
        seen = {}
        records.each do |record|
          if seen[record.key]
            counts[:skipped] += 1
            next
          end

          seen[record.key] = true
          counts[put_unless_present(record, bucket)] += 1
        end
        counts
      end

      private

      def ensure_ours(bucket)
        if bucket.nil? || bucket.to_s.strip.empty?
          raise ArgumentError, "bucket must be named, not #{bucket.inspect}"
        end

        state = @store.bucket_state(bucket, expected_owner: @owner)
        return if state == :mine

        raise BucketUnavailableError.new(bucket, state, @owner)
      end

      # The directory is read, and the zip built, only when it is needed.
      #
      # The port answers object_exists? with a boolean, and only `true` counts
      # as present. Anything else is taken for absent and the object is put:
      # the key is content-addressed, so a needless put is harmless and a
      # wrong skip is not.
      def put_unless_present(record, bucket)
        key = record.key
        return :skipped if @store.object_exists?(bucket, key, expected_owner: @owner) == true

        @store.put(bucket, key, body: Zipper.build(record), expected_owner: @owner)
        :uploaded
      end
    end
  end
end
