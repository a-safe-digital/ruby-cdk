# frozen_string_literal: true

require_relative "base"

module RubyCdk
  module Deploy
    module Output
      # For a person: the same text as Base, with a colour on what to look at.
      # Coloured only when the output is a terminal, unless color says otherwise.
      class Human < Base
        def initialize(color: nil, **options)
          super(**options)
          @color = color.nil? ? io.respond_to?(:tty?) && io.tty? : color
        end

        private

        def paint(text, code)
          code && @color ? "#{code}#{text}#{RESET}" : text
        end

        def color_for(status)
          status = status.to_s
          return RED if status.match?(/_FAILED\z|ROLLBACK/) || status == "Remove"
          return GREEN if status.match?(/_COMPLETE\z/) || status == "Add"
          return YELLOW if status.end_with?("_IN_PROGRESS") || status == "Modify"

          nil
        end
      end
    end
  end
end
