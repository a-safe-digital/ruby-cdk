# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "zlib"
require_relative "../../schema"
require_relative "compiler"
require_relative "download"
require_relative "provider_schemas"
require_relative "regions"
require_relative "resource_specification"

module RubyCdk
  module Schema
    module Sources
      # What one run of the update did.
      #
      #   region         the region the sources were taken from
      #   dir            where data/spec is
      #   changed        whether the model's content differed from the file's, and so was written
      #   model_sha256   SHA-256 of the model's JSON, the uncompressed bytes
      #   model_bytes    the size of the model's JSON
      #   gzip_bytes     the size of model.json.gz
      #   meta           META.json as a Hash
      Result = Data.define(:region, :dir, :changed, :model_sha256, :model_bytes, :gzip_bytes, :meta) do
        # The lines the rake task prints.
        def summary
          provider = meta.dig("sources", "provider_schemas")
          specification = meta.dig("sources", "resource_specification")
          counts = meta.fetch("counts")
          model = File.join(dir, RubyCdk::Schema::MODEL_FILE)
          [
            "spec: #{region}: provider schemas, #{provider.fetch("types")} types, last modified #{provider.fetch("last_modified")}; " \
              "resource specification, #{specification.fetch("types")} types, version #{meta.fetch("specification_version")}, " \
              "last modified #{specification.fetch("last_modified")}",
            "spec: model: #{counts.fetch("types")} types (#{counts.fetch("only_provider_schemas")} only in the provider schemas, " \
              "#{counts.fetch("only_resource_specification")} only in the specification); #{model_bytes} bytes of JSON, " \
              "#{gzip_bytes} bytes gzipped; sha256 #{model_sha256}",
            changed ? "spec: wrote #{model} and #{File.join(dir, RubyCdk::Schema::META_FILE)}" : "spec: unchanged: #{model} already holds this model, nothing written",
            "spec: schema_version: #{meta.fetch("schema_version")}"
          ].join("\n")
        end
      end

      class << self
        # Downloads both sources for one region, judges them, compiles the model and writes
        # data/spec under dir, only when the model's content changed.
        #
        # It always downloads: the sources are the only place that says whether they moved,
        # so a run that ends in "unchanged" has asked both of them. It never deletes or
        # rewrites anything before a download has succeeded and been compiled.
        #
        # get is anything that takes a URL and answers a Download; the default is the real
        # one. now is the clock the ninety-day rule is judged against.
        #
        # Raises Regions::Unknown, SourceUnavailable (a source that cannot be reached, a
        # 404, a stale source, a body that is not what it should be), or RubyCdk::Error for
        # content this compiler cannot read. Nothing is written in any of those cases.
        def update(region:, dir:, get: Fetcher.new, now: Time.now)
          urls = Regions.urls(region)
          downloads = urls.transform_values { |url| fetch(url, get) }

          judge = Fetcher.new
          problems = downloads.values.flat_map { |download| judge.problems(download, now:) }
          raise SourceUnavailable.new(problems) if problems.any?

          provider_schemas = provider_schemas(downloads.fetch(:provider_schemas))
          specification = specification(downloads.fetch(:resource_specification))
          compiled = Compiler.new(provider_schemas:, specification:).call(region:)

          json = JSON.generate(compiled.model, sort_keys: true)
          sha256 = Digest::SHA256.hexdigest(json)
          meta = meta(region:, downloads:, compiled:, sha256:, provider_schemas:, specification:)
          changed = sha256 != existing_sha256(dir) || existing_meta_format(dir) != RubyCdk::Schema::META_FORMAT
          gz = changed ? write(dir, json, meta) : File.binread(File.join(dir, RubyCdk::Schema::MODEL_FILE))

          Result.new(region:, dir:, changed:, model_sha256: sha256, model_bytes: json.bytesize, gzip_bytes: gz.bytesize, meta:)
        end

        private

        # A machine that is offline, or a source that does not answer, is one clear line
        # and not a backtrace.
        def fetch(url, get)
          get.call(url)
        rescue RubyCdk::Error
          raise
        rescue StandardError => error
          raise SourceUnavailable.new([ "#{url}: could not be fetched (#{error.class}: #{error.message})" ])
        end

        def provider_schemas(download)
          ProviderSchemas.parse(download.body)
        rescue Zip::Error
          raise SourceUnavailable.new([ "#{download.url}: what it serves is not a zip archive" ])
        end

        def specification(download)
          ResourceSpecification.parse(download.body)
        end

        # The two files are written together, and only when the model changed or META.json
        # is missing or of another format: a source that AWS re-compresses without
        # changing its content produces no diff.
        def existing_sha256(dir)
          Digest::SHA256.hexdigest(Zlib.gunzip(File.binread(File.join(dir, RubyCdk::Schema::MODEL_FILE))))
        rescue Errno::ENOENT, Zlib::GzipFile::Error
          nil
        end

        # nil when there is no META.json under dir, or none that can be read.
        def existing_meta_format(dir)
          JSON.parse(File.read(File.join(dir, RubyCdk::Schema::META_FILE)))["meta_format"]
        rescue Errno::ENOENT, JSON::ParserError, TypeError
          nil
        end

        def write(dir, json, meta)
          FileUtils.mkdir_p(dir)
          gz = gzip(json)
          File.binwrite(File.join(dir, RubyCdk::Schema::MODEL_FILE), gz)
          File.write(File.join(dir, RubyCdk::Schema::META_FILE), JSON.pretty_generate(meta, sort_keys: true) + "\n")
          gz
        end

        # gzip with a zero modification time and no operating-system mark, so that the same
        # model gives the same bytes on every machine.
        def gzip(json)
          gz = Zlib.gzip(json)
          gz[4, 4] = "\0\0\0\0"
          gz.setbyte(9, 255)
          gz
        end

        def meta(region:, downloads:, compiled:, sha256:, provider_schemas:, specification:)
          provider = downloads.fetch(:provider_schemas)
          {
            "region" => region,
            "meta_format" => RubyCdk::Schema::META_FORMAT,
            "model_format" => RubyCdk::Schema::MODEL_FORMAT,
            "model_sha256" => sha256,
            "schema_version" => schema_version(specification:, sha256:),
            "specification_version" => specification.version,
            "counts" => compiled.counts,
            "sources" => {
              "provider_schemas" => source(provider, types: provider_schemas.size),
              "resource_specification" => source(downloads.fetch(:resource_specification), types: specification.resource_types.size)
            }
          }
        end

        # What the manifest records as schema_version, in one String: the version of the
        # resource specification, the identity of the model, and the format a loader must
        # speak. It changes exactly when the model does. The provider schemas have no
        # version number, and their Last-Modified is not put here on purpose: AWS
        # republishes the zip with other bytes but the same schemas several times a day,
        # which moves that moment and not the model. It stays in META.json.
        def schema_version(specification:, sha256:)
          "resource specification #{specification.version}, model sha256:#{sha256}, model format #{RubyCdk::Schema::MODEL_FORMAT}"
        end

        # What one source was: its address, when AWS last changed it, its ETag, and the
        # SHA-256 of the bytes as served.
        def source(download, types:)
          {
            "url" => download.url,
            "last_modified" => download.last_modified&.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "etag" => download.etag,
            "sha256" => Digest::SHA256.hexdigest(download.body),
            "bytes" => download.body.bytesize,
            "types" => types
          }
        end
      end
    end
  end
end
