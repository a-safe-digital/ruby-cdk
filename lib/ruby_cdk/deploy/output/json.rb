# frozen_string_literal: true

require "json"
require_relative "base"

module RubyCdk
  module Deploy
    module Output
      # For --json: everything the engine says is one JSON object per line, on
      # io, each with a `type`. Standard out is left whole for the command,
      # which prints the result of the deploy.
      class Json < Base
        def target(account:, region:, profile:)
          emit(type: "target", account: account, region: region, profile: profile)
        end

        def changes(list, capabilities: nil)
          emit(type: "changes", changes: list.map { |change| plain(change.to_h) }, capabilities: Array(capabilities))
        end

        def ask(question)
          emit(type: "ask", question: question)
          return false unless interactive?

          %w[y yes].include?(read_line.to_s.downcase)
        end

        def confirm(text)
          emit(type: "confirm", text: text)
          return false unless interactive?

          read_line == text
        end

        def event(event)
          emit(type: "event", event: plain(event.to_h))
        end

        def outputs(hash)
          emit(type: "outputs", outputs: hash)
        end

        def failure(detail)
          emit(type: "failure", message: detail.to_s)
        end

        def retained(list)
          emit(type: "retained", resources: list.map { |resource| plain(resource.to_h) })
        end

        def announce(text)
          emit(type: "announce", message: text)
        end

        private

        # A time is written as CloudFormation writes it, in UTC.
        def plain(hash)
          hash.transform_values do |value|
            value.respond_to?(:utc) ? value.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ") : value
          end
        end

        def emit(hash)
          io.puts JSON.generate(hash)
        end
      end
    end
  end
end
