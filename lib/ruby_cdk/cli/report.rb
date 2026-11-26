# frozen_string_literal: true

module RubyCdk
  module Cli
    # Prints what a command ended with and answers its exit code (architecture
    # section 14). The exit code is the error's class, never its message:
    # RubyCdk::Deploy.exit_code_for decides, and the command line adds nothing
    # to it except its own usage errors, which are 1.
    #
    # Every failure ends with the line that names the command to run next. The
    # engine's errors already carry theirs in their message; the command line's
    # own carry it in Cli::Usage#next_step; and an app file that raised says
    # which file to correct and which command to run again.
    def self.report(error, io:, command:)
      case error
      when AppFileError
        app_file(error, io, command)
      when Usage
        io.failure("ruby-cdk: #{error.message}")
        io.say(error.next_step) if error.next_step
        USAGE
      when RubyCdk::ValidationError
        io.failure(text(error))
        io.say("Correct the template and run `ruby-cdk #{command}` again.")
        Deploy.exit_code_for(error)
      when RubyCdk::Error
        approval(error, io, command)
        Deploy.exit_code_for(error)
      when ->(error) { credential_failure?(error) }
        # An AWS credential or SSO failure (InvalidSSOToken, an expired token, a
        # profile that cannot refresh): a precondition of the run, not a bug.
        # The SDK's message is printed first; the command to run next is ours.
        io.failure("ruby-cdk: #{text(error)}")
        io.say("The AWS session or the credentials are not usable. Run `aws sso login --profile PROFILE` " \
          "(or refresh the credentials another way), then run the command again.")
        USAGE
      when Thor::Error
        # Thor's own usage errors: an unknown command, an unknown option, an
        # option without its value. The commands named there, when there is
        # one, are what the help should be asked about; `help` and its flags
        # are no command of this tool's.
        io.failure("ruby-cdk: #{error.message}")
        about = command && command != "help" && !%w[-h -? --help -D].include?(command) ? " #{command}" : ""
        io.say("Run `ruby-cdk help#{about}` to see what #{about.empty? ? "the commands are" : "it takes"}.")
        USAGE
      else
        io.failure("ruby-cdk: #{error.class}: #{text(error)}")
        io.failure("This is not a failure the command line knows how to explain, so nothing more can be said " \
          "about what the command did before it.")
        io.say(error.backtrace.join("\n")) if io.verbose && error.backtrace
        io.failure("Report it as a bug in ruby-cdk, with the command and this output.")
        USAGE
      end
    end

    # An app file that raised (architecture section 11): the class, the message
    # and the first frame that is in the file. The gem's backtrace only with --verbose.
    def self.app_file(error, io, command)
      if error.gem_error?
        io.failure("ruby-cdk: #{text(error.error)}")
        io.say("    at #{error.path}: #{error.location}") if error.location
      else
        io.failure("#{error.path}: #{error.location || "no line of it raised it; the failure came from what it loaded"}")
        io.failure("#{error.error.class}: #{text(error.error)}")
      end
      io.say(error.backtrace.join("\n")) if io.verbose
      io.say("Correct #{error.path} and run `ruby-cdk #{command}` again.")
      USAGE
    end

    # An error's message, as text a terminal takes: an app file can raise with
    # bytes in its message that are not UTF-8.
    def self.text(error)
      error.message.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
    end

    # True for the AWS errors that mean "the session or the credentials cannot
    # be used": an SSO token that expired and failed to refresh, a token that
    # cannot be retrieved at all, credentials that could not be found, the
    # metadata endpoint probed in vain. Matched on the class name (which names
    # the failure: InvalidSSOToken, SSOError...) and on the message, so nothing
    # Aws:: is loaded to ask.
    CREDENTIAL_FAILURE = /SSO|Token|InvalidClientTokenId|unable to sign request|ExpiredToken|Failed to open TCP connection to 169\.254|Loading credentials/.freeze

    def self.credential_failure?(error)
      error.class.name.start_with?("Aws::") && CREDENTIAL_FAILURE.match?("#{error.class.name} #{text(error)}")
    end

    # An approval that was not given (exit 4). When nobody could have given it,
    # because no terminal is attached to answer, the CDK refuses with what is
    # missing and the two ways out, and that shape is what a person needs
    # (packages/aws-cdk/lib/cli/user-input.ts in aws-cdk-cli, the prompt's
    # refusal). What was already made is named as it is: the engine deletes a
    # change set that was refused, and deletes the stack a creation made
    # (architecture section 9, housekeeping). In a terminal it was a decision:
    # the engine's own message says so, and carries the stack and what it left.
    def self.approval(error, io, command)
      if error.is_a?(Deploy::ApprovalRequired) && !io.interactive?
        done = command == "destroy" ? "nothing was deleted" : "nothing was deployed"
        io.failure("ruby-cdk: No terminal is attached to answer the question, so the command stopped, and #{done}.")
        io.say("Run `ruby-cdk #{command}` again with --yes to do it without the question, or run it in a terminal to answer it.")
      else
        io.failure(text(error))
      end
    end
  end
end
