# frozen_string_literal: true

require "test_helper"
require_relative "../../support/schema_fixtures"

# `rake spec:update` end to end, with the downloads injected: what it writes, when it writes
# nothing, and the alarm of decision D-005. No test here reaches the network.
class SourcesUpdateTest < Minitest::Test
  Sources = RubyCdk::Schema::Sources
  Fixtures = SchemaFixtures

  MODEL = RubyCdk::Schema::MODEL_FILE
  META = RubyCdk::Schema::META_FILE
  DAY = 24 * 60 * 60

  # The files under dir: their bytes and their modification times.
  def snapshot(dir)
    Dir.children(dir).sort.to_h { |name| [name, [File.binread(File.join(dir, name)), File.mtime(File.join(dir, name))]] }
  end

  def model_bytes(dir)
    File.binread(File.join(dir, MODEL))
  end

  def test_the_first_run_writes_the_model_and_its_meta
    Fixtures.in_a_temporary_directory do |dir|
      zip = Fixtures.provider_bytes
      result = Fixtures.update(dir, Fixtures.downloads(zip:))

      assert result.changed
      assert_equal "us-east-1", result.region
      assert_equal dir, result.dir
      assert_equal [META, MODEL], Dir.children(dir).sort

      json = Zlib.gunzip(model_bytes(dir))
      assert_equal json.bytesize, result.model_bytes
      assert_equal model_bytes(dir).bytesize, result.gzip_bytes
      assert_equal Digest::SHA256.hexdigest(json), result.model_sha256
      assert_equal result.meta, JSON.parse(File.read(File.join(dir, META)))

      meta = result.meta
      assert_equal %w[counts model_sha256 region sources specification_version], meta.keys.sort
      assert_equal "us-east-1", meta["region"]
      assert_equal "1.2.3", meta["specification_version"]
      assert_equal({ "types" => 4, "provider_schemas" => 2, "resource_specification" => 3, "only_provider_schemas" => 1, "only_resource_specification" => 2 }, meta["counts"])
      provider = meta["sources"]["provider_schemas"]
      assert_equal [Fixtures::PROVIDER_URL, "2026-11-01T09:30:00Z", "\"fixture\"", Digest::SHA256.hexdigest(zip), zip.bytesize, 2],
        provider.values_at("url", "last_modified", "etag", "sha256", "bytes", "types")
      assert_equal [Fixtures::SPECIFICATION_URL, 3], meta["sources"]["resource_specification"].values_at("url", "types")

      # What was written is what the loader reads.
      model = RubyCdk::Schema::Model.load(dir)
      assert_equal meta, model.meta
      assert_equal 4, model.types.size
      assert_equal :immutable, model.type("AWS::Demo::Widget").update_behaviour("Name")
    end
  end

  def test_the_same_sources_give_the_same_bytes_every_time
    built = 2.times.map do
      Fixtures.in_a_temporary_directory do |dir|
        Fixtures.update(dir)
        snapshot(dir).transform_values(&:first)
      end
    end

    assert_equal built.first, built.last
  end

  def test_the_model_is_gzipped_with_no_time_and_no_machine_mark
    Fixtures.in_a_temporary_directory do |dir|
      Fixtures.update(dir)
      header = model_bytes(dir).byteslice(0, 10)

      assert_equal [0x1f, 0x8b, 8, 0], header.bytes.first(4)     # a gzip of deflate data, no flags
      assert_equal [0, 0, 0, 0], header.byteslice(4, 4).bytes    # no modification time
      assert_equal 255, header.byteslice(9, 1).getbyte(0)        # no operating system
    end
  end

  def test_a_second_run_writes_nothing_when_the_model_did_not_change
    Fixtures.in_a_temporary_directory do |dir|
      Fixtures.update(dir)
      before = snapshot(dir)

      result = Fixtures.update(dir)

      refute result.changed
      assert_equal before, snapshot(dir)
      assert_match(/nothing written/, result.summary)
    end
  end

  def test_a_source_aws_recompressed_changes_nothing
    Fixtures.in_a_temporary_directory do |dir|
      Fixtures.update(dir)
      before = snapshot(dir)
      again = Fixtures.downloads(
        zip: Fixtures.provider_bytes(Fixtures.provider_schemas.values.reverse),   # the same schemas, in another order
        specification: JSON.generate(Fixtures.specification)                      # the same document, not gzipped
      )

      refute Fixtures.update(dir, again).changed
      assert_equal before, snapshot(dir)
    end
  end

  def test_a_changed_source_rewrites_both_files
    Fixtures.in_a_temporary_directory do |dir|
      Fixtures.update(dir)
      document = Fixtures.specification
      document["ResourceTypes"]["AWS::Demo::Open"]["Properties"]["Extra"] = { "UpdateType" => "Mutable", "Required" => false, "PrimitiveType" => "String" }

      result = Fixtures.update(dir, Fixtures.downloads(specification: Zlib.gzip(JSON.generate(document))))

      assert result.changed
      assert_equal :string, RubyCdk::Schema::Model.load(dir).type("AWS::Demo::Open").properties["Extra"].kind
      assert_equal result.model_sha256, Digest::SHA256.hexdigest(Zlib.gunzip(model_bytes(dir)))
    end
  end

  def test_a_broken_model_file_is_rebuilt
    Fixtures.in_a_temporary_directory do |dir|
      Fixtures.update(dir)
      File.binwrite(File.join(dir, MODEL), "truncated")

      result = Fixtures.update(dir)

      assert result.changed
      assert_equal :immutable, RubyCdk::Schema::Model.load(dir).type("AWS::Demo::Widget").update_behaviour("Name")
    end
  end

  def test_a_missing_meta_is_written_again
    Fixtures.in_a_temporary_directory do |dir|
      Fixtures.update(dir)
      File.delete(File.join(dir, META))

      result = Fixtures.update(dir)

      assert result.changed
      assert_equal [META, MODEL], Dir.children(dir).sort
      assert_equal result.meta, JSON.parse(File.read(File.join(dir, META)))
    end
  end

  def test_a_404_fails_loudly_and_writes_nothing
    Fixtures.in_a_temporary_directory do |dir|
      gone = Fixtures.downloads(zip: Fixtures.download(Fixtures::PROVIDER_URL, "", status: 404))

      error = assert_raises(Sources::SourceUnavailable) { Fixtures.update(dir, gone) }

      assert_equal ["#{Fixtures::PROVIDER_URL}: HTTP 404. AWS has stopped publishing it there: see decision D-005"], error.problems
      assert_match(/left as it is/, error.message)
      assert_empty Dir.children(dir)
    end
  end

  def test_a_source_that_has_not_changed_for_over_ninety_days_fails
    Fixtures.in_a_temporary_directory do |dir|
      stale = Fixtures.downloads(last_modified: Fixtures::NOW - 91 * DAY)

      error = assert_raises(Sources::SourceUnavailable) { Fixtures.update(dir, stale) }

      assert_equal 2, error.problems.size
      error.problems.each { |problem| assert_match(/days ago, more than the 90 of decision D-005/, problem) }
      assert_empty Dir.children(dir)
    end
  end

  def test_every_problem_is_reported_at_once
    Fixtures.in_a_temporary_directory do |dir|
      broken = Fixtures.downloads(
        zip: Fixtures.download(Fixtures::PROVIDER_URL, "", status: 403),
        last_modified: Fixtures::NOW - 100 * DAY
      )

      error = assert_raises(Sources::SourceUnavailable) { Fixtures.update(dir, broken) }

      assert_equal 2, error.problems.size
      assert_match(/HTTP 403/, error.message)
      assert_match(/days ago/, error.message)
      assert_empty Dir.children(dir)
    end
  end

  def test_a_source_exactly_ninety_days_old_is_still_fresh
    Fixtures.in_a_temporary_directory do |dir|
      result = Fixtures.update(dir, Fixtures.downloads(last_modified: Fixtures::NOW - 90 * DAY))

      assert result.changed
    end
  end

  def test_a_source_without_last_modified_fails
    Fixtures.in_a_temporary_directory do |dir|
      error = assert_raises(Sources::SourceUnavailable) { Fixtures.update(dir, Fixtures.downloads(last_modified: nil)) }

      assert_match(/no Last-Modified header/, error.message)
      assert_empty Dir.children(dir)
    end
  end

  def test_a_body_that_is_not_a_zip_is_the_alarm_too
    Fixtures.in_a_temporary_directory do |dir|
      not_a_zip = Fixtures.downloads(zip: "<html>redirected</html>")

      error = assert_raises(Sources::SourceUnavailable) { Fixtures.update(dir, not_a_zip) }

      assert_match(/#{Regexp.escape(Fixtures::PROVIDER_URL)}: what it serves is not a zip archive/, error.message)
      assert_empty Dir.children(dir)
    end
  end

  def test_a_specification_that_is_not_json_fails
    Fixtures.in_a_temporary_directory do |dir|
      error = assert_raises(RubyCdk::Error) { Fixtures.update(dir, Fixtures.downloads(specification: "<html>")) }

      assert_match(/not JSON/, error.message)
      assert_empty Dir.children(dir)
    end
  end

  def test_an_unknown_region_is_refused_before_anything_is_asked_for
    Fixtures.in_a_temporary_directory do |dir|
      asked = []

      assert_raises(Sources::Regions::Unknown) do
        Sources.update(region: "ap-south-9", dir:, get: ->(url) { asked << url })
      end

      assert_empty asked
      assert_empty Dir.children(dir)
    end
  end

  def test_the_summary_says_what_happened
    Fixtures.in_a_temporary_directory do |dir|
      summary = Fixtures.update(dir).summary

      assert_match(/us-east-1: provider schemas, 2 types/, summary)
      assert_match(/resource specification, 3 types, version 1.2.3/, summary)
      assert_match(/model: 4 types \(1 only in the provider schemas, 2 only in the specification\)/, summary)
      assert_match(/bytes of JSON, \d+ bytes gzipped; sha256 [0-9a-f]{64}/, summary)
      assert_match(/wrote .*model\.json\.gz and .*META\.json/, summary)
    end
  end
end
