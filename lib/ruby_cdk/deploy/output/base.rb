# frozen_string_literal: true

require_relative "../ports"
require_relative "../capabilities"

module RubyCdk
  module Deploy
    module Output
      # What the outputs share, in plain text: what happens goes to io (standard
      # error), the outputs to result_io (standard out), and a question is asked
      # only where it can be answered. Human adds colour to this, Quiet leaves
      # out the progress.
      #
      # Nothing here knows a credential. What crosses this interface is an
      # account ID, a region, a profile name, changes, events and outputs; the
      # values of template properties and of parameters are never in them.
      class Base
        include Output

        RESET = "\e[0m"
        BOLD = "\e[1m"
        RED = "\e[31m"
        GREEN = "\e[32m"
        YELLOW = "\e[33m"
        CYAN = "\e[36m"

        def initialize(io: $stderr, stdin: $stdin, result_io: $stdout)
          @io = io
          @stdin = stdin
          @result_io = result_io
        end

        def target(account:, region:, profile:)
          say("#{paint("Target", BOLD)}: account #{account}, region #{region}, profile #{profile || "the default credential chain"}")
        end

        # The change view. It names the properties that change, never their values.
        def changes(list, capabilities: nil)
          return if list.empty?

          say(paint("Changes", BOLD))
          list.each do |change|
            action = change.action.to_s
            line = "  #{paint(action.ljust(8), color_for(action))}#{change.logical_id}  #{change.resource_type}"
            line += "  #{paint(change.replacement, CYAN)}" if change.replacement && change.replacement != "False"
            say(line)
            names = changed_properties(change)
            say("          #{names.join(", ")}") if names.any?
          end
          needed = Array(capabilities)
          say("  #{capabilities_line(needed)}") if needed.any?
        end

        # Nobody there to answer is a no. The engine says what to do about it.
        def ask(question)
          return false unless interactive?

          say("#{paint("?", BOLD)} #{question} #{paint("[y/N]", YELLOW)} ")
          %w[y yes].include?(read_line.to_s.downcase)
        end

        def confirm(text)
          return false unless interactive?

          say("To confirm, type #{text.inspect}: ")
          read_line == text
        end

        # One line per event: the time, the status in a column, what it is about,
        # and why when it failed.
        def event(event)
          status = event.resource_status.to_s
          what = [ event.resource_type, event.logical_id ].compact.join("  ")
          reason = event.status_reason.to_s if status.end_with?("_FAILED") && event.status_reason.to_s.size > 0
          status = status.ljust(34) unless what.empty? || status.length >= 34

          say([ "  #{moment(event)}", paint(status, color_for(status)), what, reason ].compact.reject(&:empty?).join("  "))
        end

        def outputs(hash)
          return if hash.nil? || hash.empty?

          result_io.puts "Outputs:"
          hash.each { |key, value| result_io.puts "  #{key} = #{value}" }
        end

        def failure(detail)
          say(paint(detail.to_s, RED))
        end

        def retained(list)
          return if list.empty?

          say(paint("Kept after the stack is deleted (their DeletionPolicy says so):", YELLOW))
          list.each { |resource| say("  #{resource.logical_id}  #{resource.resource_type}  #{resource.deletion_policy}") }
        end

        def announce(text)
          say(text)
        end

        private

        attr_reader :io, :stdin, :result_io

        def say(text)
          io.puts text
        end

        # True when there is somebody to answer: a terminal on standard input.
        def interactive?
          stdin.respond_to?(:tty?) && stdin.tty?
        end

        # One line from the person, or nil. Interrupting the question is not an answer.
        def read_line
          stdin.gets&.strip
        rescue Interrupt
          nil
        end

        # [attribute: name] for what a change touches. The detail comes in the
        # shape CloudFormation describes it.
        def changed_properties(change)
          Array(change.detail).filter_map do |entry|
            next unless entry.is_a?(Hash)

            target = entry[:target] || entry["target"]
            next unless target.is_a?(Hash)

            name = target[:name] || target["name"]
            next if name.nil?

            "#{target[:attribute] || target["attribute"] || "Properties"}: #{name}"
          end
        end

        def capabilities_line(capabilities)
          reason = if capabilities.include?(Capabilities::NAMED_IAM)
            "the template creates IAM resources, some with explicit names"
          else
            "the template creates IAM resources"
          end
          paint("Capabilities needed: #{capabilities.join(", ")}, because #{reason}.", CYAN)
        end

        def moment(event)
          if event.timestamp.respond_to?(:utc)
            event.timestamp.utc.strftime("%H:%M:%SZ")
          else
            "--:--:--"
          end
        end

        # Human puts a colour around text; here there is none.
        def paint(text, _code)
          text
        end

        # The colour of a status or an action, for Human.
        def color_for(_status)
          nil
        end
      end
    end
  end
end
