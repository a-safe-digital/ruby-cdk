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

        # Red is what went wrong or was rolled back; yellow is what is under
        # way, a rollback included; green is what succeeded. A rollback in
        # progress is not a failure yet, so what is still in progress is asked
        # first: UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS is under way.
        def color_for(status)
          status = status.to_s
          return YELLOW if status.end_with?("_IN_PROGRESS") || status == "Modify"
          return RED if status.end_with?("_FAILED") || status.include?("ROLLBACK_COMPLETE") || status == "Remove"
          return GREEN if status.end_with?("_COMPLETE") || status == "Add"

          nil
        end
      end
    end
  end
end
