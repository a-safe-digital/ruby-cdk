# frozen_string_literal: true

require_relative "base"

module RubyCdk
  module Deploy
    module Output
      # For --quiet: no progress. What a decision needs is still said: the
      # target, the resources a destroy will keep, a question. So are a failure
      # and the outputs.
      class Quiet < Base
        def changes(list, capabilities: nil); end

        def event(event); end

        def announce(text); end
      end
    end
  end
end
