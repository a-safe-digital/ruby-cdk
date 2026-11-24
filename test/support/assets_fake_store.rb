# frozen_string_literal: true

# An in-memory object store for the asset tests: the three methods of the
# object-store port, buckets with an owner, and the log of every call, so that
# a test can assert what reached the store and with which expected owner.
class AssetsFakeObjectStore
  Call = Data.define(:name, :bucket, :key, :expected_owner, :body)

  # What S3 answers, 403, when the expected owner is not the bucket's owner.
  class Forbidden < StandardError; end

  attr_reader :owner, :buckets, :objects, :calls

  # owner: the account that owns the buckets added afterwards.
  def initialize(owner: "111122223333")
    @owner = owner
    @buckets = {} # "bucket" => the account that owns it
    @objects = {} # [ "bucket", "key" ] => body
    @calls = []
  end

  def add_bucket(name, owner: @owner)
    @buckets[name] = owner
    self
  end

  def add_object(bucket, key, body = "")
    add_bucket(bucket) unless @buckets.key?(bucket)
    @objects[[ bucket, key ]] = body
    self
  end

  # :absent, :foreign or :mine. Never :mine unless the expected owner is the
  # bucket's owner.
  def bucket_state(name, expected_owner:)
    log(:bucket_state, name, nil, expected_owner)
    return :absent unless @buckets.key?(name)

    @buckets[name] == expected_owner ? :mine : :foreign
  end

  def object_exists?(bucket, key, expected_owner:)
    log(:object_exists?, bucket, key, expected_owner)
    refuse!(bucket, expected_owner)
    @objects.key?([ bucket, key ])
  end

  def put(bucket, key, body:, expected_owner:)
    log(:put, bucket, key, expected_owner, body)
    refuse!(bucket, expected_owner)
    @objects[[ bucket, key ]] = body
  end

  # Every call to one of the three methods.
  def calls_to(name)
    @calls.select { |call| call.name == name }
  end

  def body(bucket, key)
    @objects[[ bucket, key ]]
  end

  private

  def log(name, bucket, key, expected_owner, body = nil)
    @calls << Call.new(name:, bucket:, key:, expected_owner:, body:)
  end

  def refuse!(bucket, expected_owner)
    return if @buckets.key?(bucket) && @buckets[bucket] == expected_owner

    raise Forbidden, "403 for #{bucket}: expected owner #{expected_owner.inspect}"
  end
end
