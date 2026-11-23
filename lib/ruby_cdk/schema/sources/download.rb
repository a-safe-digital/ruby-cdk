# frozen_string_literal: true

require "net/http"
require "time"
require "uri"
require_relative "../../errors"

module RubyCdk
  module Schema
    module Sources
      # What one GET returned.
      #
      #   url            the address that was asked for
      #   status         the HTTP status code
      #   body           the bytes as served
      #   last_modified  the Last-Modified header as a Time, or nil when absent or unreadable
      #   etag           the ETag header as served, or nil
      Download = Data.define(:url, :status, :body, :last_modified, :etag)

      # A source AWS no longer publishes, or has not changed for ninety days: the alarm of
      # decision D-005. Nothing is written when it is raised.
      class SourceUnavailable < RubyCdk::Error
        attr_reader :problems

        # problems: one line per thing that is wrong.
        def initialize(problems)
          @problems = problems.freeze
          super([ "a schema source is gone or stale, so data/spec was left as it is:", *problems.map { |problem| "  - #{problem}" } ].join("\n"))
        end
      end

      # Fetches a URL with Net::HTTP and judges whether what came back can be trusted.
      class Fetcher
        # Decision D-005: ninety days without a change means the source is dead.
        MAX_AGE = 90 * 24 * 60 * 60

        DAY = 24 * 60 * 60
        OPEN_TIMEOUT = 30
        READ_TIMEOUT = 120

        GONE = ". AWS has stopped publishing it there: see decision D-005"

        # GET url. A network failure raises, as a task that cannot reach its source should.
        #
        # body is the file as AWS stores it, not what Net::HTTP would hand over: left to
        # itself it asks for gzip and quietly decodes a Content-Encoding body, which for
        # the specification is 20 MB of JSON where the file is 1 MB of gzip. So this asks
        # for gzip itself, which turns that decoding off, and the SHA-256 recorded in
        # META.json is what `curl URL | shasum -a 256` prints.
        def call(url)
          uri = URI.parse(url)
          request = Net::HTTP::Get.new(uri.request_uri)
          request["Accept-Encoding"] = "gzip"
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
            http.request(request)
          end
          Download.new(url:, status: response.code.to_i, body: response.body, last_modified: http_time(response["Last-Modified"]), etag: response["ETag"])
        end

        # What is wrong with a download: empty when the source answered and is fresh.
        def problems(download, now:)
          return [ "#{download.url}: HTTP #{download.status}#{download.status == 404 ? GONE : ""}" ] unless download.status == 200
          return [ "#{download.url}: no Last-Modified header, so its age cannot be checked" ] unless download.last_modified

          age = now - download.last_modified
          return [] unless age > MAX_AGE

          [ "#{download.url}: Last-Modified #{download.last_modified.utc.strftime("%Y-%m-%d")}, #{(age / DAY).floor} days ago, " \
            "more than the #{MAX_AGE / DAY} of decision D-005" ]
        end

        private

        def http_time(value)
          return nil unless value

          Time.httpdate(value)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
